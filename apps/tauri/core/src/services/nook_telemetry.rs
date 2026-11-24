//! Nook's own OpenTelemetry records (`NookTelemetry`, `TelemetryBuffer` and `TelemetryRecords` on the Mac).
//!
//! Off by default and free when off: with no endpoint every call returns after one locked read, nothing is buffered,
//! no timer runs and no connection opens. When on, Nook records a few things of its own: each agent turn (a span with
//! the agent, model, outcome, duration and tokens, the same as sums, and a log record), each scheduled task run, and
//! the app's launch. Records wait in a [`TelemetryBuffer`] and go out together every few seconds as OTLP/HTTP JSON. A
//! receiver that does not answer loses that export and rests a minute; nothing is retried. No prompts, answers, file
//! contents, paths or session ids are sent.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use uuid::Uuid;

use super::telemetry::{
    privacy_safe_resource, OtlpConfig, OtlpExporter, OtlpLogRecord, OtlpPayload, OtlpSeverity, OtlpSignal, OtlpSpan, OtlpSum, OtlpValue,
};
use crate::workspace::models::{RunStatus, RunUsage, WorkspaceRun};
use crate::workspace::schedule::{ScheduleTrigger, ScheduledRunStatus};

/// How long records wait before they go out together.
pub const FLUSH_DELAY: Duration = Duration::from_secs(10);

// MARK: Buffer

/// What waits to be sent. Spans and logs keep the newest `limit`; sums with the same name and attributes add up.
#[derive(Debug, Clone)]
pub struct TelemetryBuffer {
    pub limit: usize,
    pub pause: chrono::Duration,
    spans: Vec<OtlpSpan>,
    logs: Vec<OtlpLogRecord>,
    sums: Vec<OtlpSum>,
    sums_since: Option<DateTime<Utc>>,
    paused_until: BTreeMap<OtlpSignal, DateTime<Utc>>,
}

impl Default for TelemetryBuffer {
    fn default() -> Self {
        Self {
            limit: 256,
            pause: chrono::Duration::seconds(60),
            spans: Vec::new(),
            logs: Vec::new(),
            sums: Vec::new(),
            sums_since: None,
            paused_until: BTreeMap::new(),
        }
    }
}

/// Everything a flush takes out of the buffer.
#[derive(Debug, Clone, Default)]
pub struct TelemetryBatch {
    pub spans: Vec<OtlpSpan>,
    pub logs: Vec<OtlpLogRecord>,
    pub sums: Vec<OtlpSum>,
    pub sums_since: Option<DateTime<Utc>>,
}

impl TelemetryBuffer {
    pub fn is_empty(&self) -> bool {
        self.spans.is_empty() && self.logs.is_empty() && self.sums.is_empty()
    }

    pub fn is_paused(&self, signal: OtlpSignal, now: DateTime<Utc>) -> bool {
        self.paused_until.get(&signal).is_some_and(|until| now < *until)
    }

    pub fn add_span(&mut self, span: OtlpSpan, now: DateTime<Utc>) {
        if self.is_paused(OtlpSignal::Traces, now) {
            return;
        }
        self.spans.push(span);
        if self.spans.len() > self.limit {
            let extra = self.spans.len() - self.limit;
            self.spans.drain(..extra);
        }
    }

    pub fn add_log(&mut self, record: OtlpLogRecord, now: DateTime<Utc>) {
        if self.is_paused(OtlpSignal::Logs, now) {
            return;
        }
        self.logs.push(record);
        if self.logs.len() > self.limit {
            let extra = self.logs.len() - self.limit;
            self.logs.drain(..extra);
        }
    }

    pub fn add_sum(&mut self, sum: OtlpSum, now: DateTime<Utc>) {
        if self.is_paused(OtlpSignal::Metrics, now) {
            return;
        }
        if let Some(existing) = self.sums.iter_mut().find(|s| s.name == sum.name && s.attributes == sum.attributes) {
            existing.value += sum.value;
        } else if self.sums.len() < self.limit {
            self.sums.push(sum);
        }
        self.sums_since.get_or_insert(now);
    }

    /// Everything waiting, taken out for one export.
    pub fn drain(&mut self) -> TelemetryBatch {
        TelemetryBatch {
            spans: std::mem::take(&mut self.spans),
            logs: std::mem::take(&mut self.logs),
            sums: std::mem::take(&mut self.sums),
            sums_since: self.sums_since.take(),
        }
    }

    /// The receiver of a signal did not take an export: that export is gone, and the signal rests for `pause`.
    pub fn failed(&mut self, signal: OtlpSignal, now: DateTime<Utc>) {
        self.paused_until.insert(signal, now + self.pause);
    }

    pub fn succeeded(&mut self, signal: OtlpSignal) {
        self.paused_until.remove(&signal);
    }
}

// MARK: Records

/// The records of one finished agent turn. Only counts and names: no prompt, answer, path or session id.
pub struct TurnRecords {
    pub span: OtlpSpan,
    pub sums: Vec<OtlpSum>,
    pub log: OtlpLogRecord,
}

fn status_name(status: RunStatus) -> &'static str {
    match status {
        RunStatus::Preparing => "preparing",
        RunStatus::Running => "running",
        RunStatus::WaitingApproval => "waitingApproval",
        RunStatus::Completed => "completed",
        RunStatus::Failed => "failed",
        RunStatus::Stopped => "stopped",
    }
}

fn scheduled_status_name(status: ScheduledRunStatus) -> &'static str {
    match status {
        ScheduledRunStatus::Running => "running",
        ScheduledRunStatus::Succeeded => "succeeded",
        ScheduledRunStatus::Failed => "failed",
        ScheduledRunStatus::Skipped => "skipped",
    }
}

fn sum(name: &str, unit: &str, description: &str, attributes: BTreeMap<String, OtlpValue>, value: f64, is_integer: bool) -> OtlpSum {
    OtlpSum { name: name.into(), unit: unit.into(), description: description.into(), attributes, value, is_integer }
}

/// `TelemetryRecords.turn` on the Mac: a span, sums (turns, duration, tokens per kind) and a log record.
pub fn turn_records(run: &WorkspaceRun, started: DateTime<Utc>, before: &RunUsage, now: DateTime<Utc>) -> TurnRecords {
    let provider = run.provider.id().to_string();
    let outcome = status_name(run.status).to_string();
    let mut attributes: BTreeMap<String, OtlpValue> = BTreeMap::new();
    attributes.insert("nook.agent.provider".into(), OtlpValue::String(provider.clone()));
    attributes.insert("nook.agent.outcome".into(), OtlpValue::String(outcome.clone()));
    attributes.insert("nook.agent.remote".into(), OtlpValue::Bool(false));
    if !run.model.is_empty() {
        attributes.insert("nook.agent.model".into(), OtlpValue::String(run.model.clone()));
    }
    let tokens = [
        ("input", run.usage.input_tokens, before.input_tokens),
        ("output", run.usage.output_tokens, before.output_tokens),
        ("cache_read", run.usage.cache_read_tokens, before.cache_read_tokens),
        ("cache_write", run.usage.cache_write_tokens, before.cache_write_tokens),
    ];
    let mut token_sums = Vec::new();
    for (kind, after, earlier) in tokens {
        let Some(after) = after else { continue };
        let added = after.saturating_sub(earlier.unwrap_or(0));
        attributes.insert(format!("nook.agent.tokens.{kind}"), OtlpValue::Int(added as i64));
        let mut by_kind = BTreeMap::new();
        by_kind.insert("nook.agent.provider".to_string(), OtlpValue::String(provider.clone()));
        by_kind.insert("nook.agent.token.type".to_string(), OtlpValue::String(kind.into()));
        token_sums.push(sum("nook.agent.tokens", "{token}", "Tokens agent turns used", by_kind, added as f64, true));
    }
    let ok = run.status != RunStatus::Failed;
    let span = OtlpSpan {
        trace_id: OtlpPayload::random_id(16),
        span_id: OtlpPayload::random_id(8),
        name: "nook.agent.turn".into(),
        start: started,
        end: now,
        attributes,
        ok,
        status_message: (!ok).then(|| "failed".to_string()),
    };
    let mut by_outcome = BTreeMap::new();
    by_outcome.insert("nook.agent.provider".to_string(), OtlpValue::String(provider));
    by_outcome.insert("nook.agent.outcome".to_string(), OtlpValue::String(outcome.clone()));
    let seconds = (now - started).num_milliseconds().max(0) as f64 / 1000.0;
    let mut sums = vec![
        sum("nook.agent.turns", "{turn}", "Agent turns", by_outcome.clone(), 1.0, true),
        sum("nook.agent.turn.duration", "s", "Time agent turns took", by_outcome.clone(), seconds, false),
    ];
    sums.extend(token_sums);
    let severity = match run.status {
        RunStatus::Failed => OtlpSeverity::Error,
        RunStatus::Stopped => OtlpSeverity::Warn,
        _ => OtlpSeverity::Info,
    };
    let log = OtlpLogRecord {
        time: now,
        severity,
        body: format!("agent turn {outcome}"),
        attributes: by_outcome,
        trace_id: Some(span.trace_id.clone()),
        span_id: Some(span.span_id.clone()),
    };
    TurnRecords { span, sums, log }
}

/// A scheduled task's finished run: a span and a sum, with its status and what started it.
pub fn scheduled_run_records(
    status: ScheduledRunStatus,
    trigger: Option<ScheduleTrigger>,
    started: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> (OtlpSpan, OtlpSum) {
    let mut attributes = BTreeMap::new();
    attributes.insert("nook.task.status".to_string(), OtlpValue::String(scheduled_status_name(status).into()));
    if let Some(trigger) = trigger {
        attributes.insert("nook.task.trigger".to_string(), OtlpValue::String(trigger.id().into()));
    }
    let failed = status == ScheduledRunStatus::Failed;
    let span = OtlpSpan {
        trace_id: OtlpPayload::random_id(16),
        span_id: OtlpPayload::random_id(8),
        name: "nook.scheduled_task.run".into(),
        start: started.unwrap_or(now),
        end: now,
        attributes: attributes.clone(),
        ok: !failed,
        status_message: failed.then(|| "failed".to_string()),
    };
    (span, sum("nook.scheduled_task.runs", "{run}", "Scheduled task runs", attributes, 1.0, true))
}

/// The app's launch: a span from the process's start until now.
pub fn launch_span(started: DateTime<Utc>, now: DateTime<Utc>) -> OtlpSpan {
    OtlpSpan {
        trace_id: OtlpPayload::random_id(16),
        span_id: OtlpPayload::random_id(8),
        name: "nook.app.launch".into(),
        start: started,
        end: now,
        attributes: BTreeMap::new(),
        ok: true,
        status_message: None,
    }
}

/// One OTLP/HTTP JSON body per signal that has an endpoint and records, ready to post.
pub fn payloads(batch: &TelemetryBatch, config: &OtlpConfig, version: &str, now: DateTime<Utc>) -> Vec<(OtlpSignal, String, Vec<u8>)> {
    let resource = privacy_safe_resource(version);
    let mut out = Vec::new();
    if let Some(url) = config.endpoint(OtlpSignal::Traces).filter(|_| !batch.spans.is_empty()) {
        out.push((OtlpSignal::Traces, url.to_string(), OtlpPayload::traces(&batch.spans, &resource, version)));
    }
    if let Some(url) = config.endpoint(OtlpSignal::Metrics).filter(|_| !batch.sums.is_empty()) {
        let start = batch.sums_since.unwrap_or(now);
        out.push((OtlpSignal::Metrics, url.to_string(), OtlpPayload::metrics(&batch.sums, &resource, version, start, now)));
    }
    if let Some(url) = config.endpoint(OtlpSignal::Logs).filter(|_| !batch.logs.is_empty()) {
        out.push((OtlpSignal::Logs, url.to_string(), OtlpPayload::logs(&batch.logs, &resource, version)));
    }
    out
}

// MARK: Recorder

struct State {
    config: OtlpConfig,
    buffer: TelemetryBuffer,
    flush_scheduled: bool,
    /// Per agent session: when its turn started and its usage then, so a turn's tokens are what it added.
    turn_starts: HashMap<Uuid, (DateTime<Utc>, RunUsage)>,
    runtime: Option<tokio::runtime::Handle>,
    version: String,
}

/// Nook's own export. One per process ([`shared`]); the host calls [`NookTelemetry::reload`] at launch and after a
/// change in Settings.
pub struct NookTelemetry {
    state: Mutex<State>,
    exporter: OnceLock<OtlpExporter>,
}

impl Default for NookTelemetry {
    fn default() -> Self {
        Self::new()
    }
}

impl NookTelemetry {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(State {
                config: OtlpConfig::default(),
                buffer: TelemetryBuffer::default(),
                flush_scheduled: false,
                turn_starts: HashMap::new(),
                runtime: None,
                version: env!("CARGO_PKG_VERSION").into(),
            }),
            exporter: OnceLock::new(),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Takes the configuration in effect (Settings with Nook's environment on top) and where to send from.
    pub fn reload(&self, config: OtlpConfig, runtime: Option<tokio::runtime::Handle>, version: &str) {
        let mut s = self.lock();
        let exporting = config.is_exporting();
        s.config = config;
        if runtime.is_some() {
            s.runtime = runtime;
        }
        if !version.is_empty() {
            s.version = version.into();
        }
        if exporting {
            // A changed receiver gets its chance at once.
            for signal in OtlpSignal::ALL {
                s.buffer.succeeded(signal);
            }
        } else {
            s.buffer = TelemetryBuffer::default();
            s.turn_starts.clear();
        }
    }

    pub fn config(&self) -> OtlpConfig {
        self.lock().config.clone()
    }

    /// Nook sends records of its own.
    pub fn is_exporting(&self) -> bool {
        self.lock().config.is_exporting()
    }

    /// The app finished launching: a span from `process_started` until now.
    pub fn app_launched(&self, process_started: DateTime<Utc>, now: DateTime<Utc>) {
        if !self.is_exporting() {
            return;
        }
        self.record(|b| b.add_span(launch_span(process_started, now), now));
    }

    /// An agent turn started.
    pub fn turn_started(&self, id: Uuid, usage: &RunUsage, now: DateTime<Utc>) {
        let mut s = self.lock();
        if s.config.is_exporting() {
            s.turn_starts.insert(id, (now, usage.clone()));
        }
    }

    /// An agent turn ended: a span, sums and a log record for it.
    pub fn turn_finished(&self, run: &WorkspaceRun, now: DateTime<Utc>) {
        let start = {
            let mut s = self.lock();
            if !s.config.is_exporting() {
                return;
            }
            s.turn_starts.remove(&run.id)
        };
        let Some((started, before)) = start else { return };
        let records = turn_records(run, started, &before, now);
        self.record(move |b| {
            b.add_span(records.span, now);
            for s in records.sums {
                b.add_sum(s, now);
            }
            b.add_log(records.log, now);
        });
    }

    /// A scheduled task's run ended.
    pub fn scheduled_run_finished(
        &self,
        status: ScheduledRunStatus,
        trigger: Option<ScheduleTrigger>,
        started: Option<DateTime<Utc>>,
        now: DateTime<Utc>,
    ) {
        if !self.is_exporting() || status == ScheduledRunStatus::Running {
            return;
        }
        let (span, total) = scheduled_run_records(status, trigger, started, now);
        self.record(move |b| {
            b.add_span(span, now);
            b.add_sum(total, now);
        });
    }

    /// Takes what waits out of the buffer, with the configuration and version to send it with.
    pub fn take_batch(&self) -> (TelemetryBatch, OtlpConfig, String) {
        let mut s = self.lock();
        s.flush_scheduled = false;
        (s.buffer.drain(), s.config.clone(), s.version.clone())
    }

    fn record(&self, change: impl FnOnce(&mut TelemetryBuffer)) {
        let runtime = {
            let mut s = self.lock();
            change(&mut s.buffer);
            if s.flush_scheduled || s.buffer.is_empty() {
                return;
            }
            let Some(runtime) = s.runtime.clone().or_else(|| tokio::runtime::Handle::try_current().ok()) else { return };
            s.flush_scheduled = true;
            runtime
        };
        runtime.spawn(async {
            tokio::time::sleep(FLUSH_DELAY).await;
            shared().flush().await;
        });
    }

    /// Sends everything waiting, one export per signal. A failed export is dropped and pauses its signal.
    pub async fn flush(&self) {
        let (batch, config, version) = self.take_batch();
        if !config.is_exporting() {
            return;
        }
        let exporter = self.exporter.get_or_init(OtlpExporter::new).clone();
        for (signal, url, body) in payloads(&batch, &config, &version, Utc::now()) {
            let ok = exporter.post(&url, body, &config.headers).await.is_ok_and(|status| (200..300).contains(&status));
            let mut s = self.lock();
            if ok {
                s.buffer.succeeded(signal);
            } else {
                s.buffer.failed(signal, Utc::now());
            }
        }
    }
}

/// The process-wide recorder.
pub fn shared() -> &'static NookTelemetry {
    static SHARED: OnceLock<NookTelemetry> = OnceLock::new();
    SHARED.get_or_init(NookTelemetry::new)
}

/// When this process started, from the system's process table.
pub fn process_start() -> Option<DateTime<Utc>> {
    use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};
    let pid = Pid::from_u32(std::process::id());
    let mut system = System::new().ok()?;
    system.refresh_processes_specifics(ProcessesToUpdate::Some(&[pid]), false, ProcessRefreshKind::nothing());
    let seconds = system.process(pid)?.start_time();
    Utc.timestamp_opt(seconds as i64, 0).single()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::models::RunProvider;

    fn exporting_config() -> OtlpConfig {
        let mut config = OtlpConfig { enabled: true, ..Default::default() };
        for signal in OtlpSignal::ALL {
            config.endpoints.insert(signal, format!("http://localhost:4318{}", signal.path()));
        }
        config
    }

    fn at(seconds: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000 + seconds, 0).unwrap()
    }

    fn run(status: RunStatus, usage: RunUsage) -> WorkspaceRun {
        let mut run = crate::workspace::models::tests::run(status);
        run.provider = RunProvider::Codex;
        run.model = "gpt-5".into();
        run.status = status;
        run.usage = usage;
        run
    }

    #[test]
    fn buffer_merges_sums_caps_records_and_pauses_failed_signals() {
        let mut buffer = TelemetryBuffer { limit: 2, ..Default::default() };
        for i in 0..3 {
            buffer.add_span(launch_span(at(i), at(i + 1)), at(i));
        }
        let attrs = BTreeMap::from([("a".to_string(), OtlpValue::String("x".into()))]);
        buffer.add_sum(sum("n", "1", "d", attrs.clone(), 1.0, true), at(5));
        buffer.add_sum(sum("n", "1", "d", attrs, 2.0, true), at(6));
        let batch = buffer.drain();
        assert_eq!(batch.spans.len(), 2);
        assert_eq!(batch.spans[0].start, at(1));
        assert_eq!(batch.sums.len(), 1);
        assert_eq!(batch.sums[0].value, 3.0);
        assert_eq!(batch.sums_since, Some(at(5)));
        assert!(buffer.is_empty());

        buffer.failed(OtlpSignal::Traces, at(10));
        buffer.add_span(launch_span(at(10), at(11)), at(30));
        assert!(buffer.is_empty(), "a failed signal rests a minute");
        buffer.add_span(launch_span(at(10), at(11)), at(71));
        assert!(!buffer.is_empty());
        buffer.failed(OtlpSignal::Traces, at(80));
        buffer.succeeded(OtlpSignal::Traces);
        assert!(!buffer.is_paused(OtlpSignal::Traces, at(81)));
    }

    #[test]
    fn turn_records_count_added_tokens_without_content() {
        let before = RunUsage { input_tokens: Some(100), output_tokens: Some(10), ..Default::default() };
        let after = RunUsage { input_tokens: Some(150), output_tokens: Some(40), cache_read_tokens: Some(7), ..Default::default() };
        let records = turn_records(&run(RunStatus::Failed, after), at(0), &before, at(12));
        assert_eq!(records.span.name, "nook.agent.turn");
        assert!(!records.span.ok);
        assert_eq!(records.span.attributes.get("nook.agent.tokens.input"), Some(&OtlpValue::Int(50)));
        assert_eq!(records.span.attributes.get("nook.agent.tokens.output"), Some(&OtlpValue::Int(30)));
        assert_eq!(records.span.attributes.get("nook.agent.tokens.cache_read"), Some(&OtlpValue::Int(7)));
        assert!(!records.span.attributes.contains_key("nook.agent.tokens.cache_write"));
        assert_eq!(records.span.attributes.get("nook.agent.provider"), Some(&OtlpValue::String("codex".into())));
        assert_eq!(records.span.attributes.get("nook.agent.model"), Some(&OtlpValue::String("gpt-5".into())));
        assert_eq!(records.log.severity, OtlpSeverity::Error);
        assert_eq!(records.log.body, "agent turn failed");
        let duration = records.sums.iter().find(|s| s.name == "nook.agent.turn.duration").unwrap();
        assert_eq!(duration.value, 12.0);
        assert_eq!(records.sums.iter().filter(|s| s.name == "nook.agent.tokens").count(), 3);
        // Nothing that could carry a prompt, a path or a session id.
        let keys: Vec<&String> = records.span.attributes.keys().collect();
        assert!(keys.iter().all(|k| !k.contains("path") && !k.contains("prompt") && !k.contains("session")));
    }

    #[test]
    fn scheduled_runs_carry_status_and_trigger() {
        let (span, total) = scheduled_run_records(ScheduledRunStatus::Failed, Some(ScheduleTrigger::Webhook), Some(at(0)), at(3));
        assert_eq!(span.name, "nook.scheduled_task.run");
        assert!(!span.ok);
        assert_eq!(span.start, at(0));
        assert_eq!(span.attributes.get("nook.task.trigger"), Some(&OtlpValue::String("webhook".into())));
        assert_eq!(total.attributes.get("nook.task.status"), Some(&OtlpValue::String("failed".into())));
    }

    #[test]
    fn recorder_is_silent_when_off_and_buffers_when_on() {
        let telemetry = NookTelemetry::new();
        let id = Uuid::new_v4();
        telemetry.turn_started(id, &RunUsage::default(), at(0));
        let mut finished = run(RunStatus::Completed, RunUsage::default());
        finished.id = id;
        telemetry.turn_finished(&finished, at(5));
        telemetry.scheduled_run_finished(ScheduledRunStatus::Succeeded, None, None, at(5));
        telemetry.app_launched(at(0), at(1));
        assert!(telemetry.take_batch().0.spans.is_empty());

        telemetry.reload(exporting_config(), None, "1.2.3");
        telemetry.turn_started(id, &RunUsage::default(), at(0));
        telemetry.turn_finished(&finished, at(5));
        telemetry.scheduled_run_finished(ScheduledRunStatus::Running, None, None, at(5));
        telemetry.scheduled_run_finished(ScheduledRunStatus::Succeeded, Some(ScheduleTrigger::Manual), Some(at(1)), at(5));
        telemetry.app_launched(at(0), at(1));
        let (batch, config, version) = telemetry.take_batch();
        assert_eq!(version, "1.2.3");
        assert_eq!(batch.spans.len(), 3);
        assert_eq!(batch.logs.len(), 1);
        let bodies = payloads(&batch, &config, &version, at(6));
        assert_eq!(bodies.iter().map(|(s, _, _)| *s).collect::<Vec<_>>(), OtlpSignal::ALL.to_vec());
        let traces: serde_json::Value = serde_json::from_slice(&bodies[0].2).unwrap();
        assert_eq!(traces["resourceSpans"][0]["scopeSpans"][0]["spans"].as_array().unwrap().len(), 3);

        // Turning it off drops what waited and the turns in flight.
        telemetry.turn_started(id, &RunUsage::default(), at(0));
        telemetry.reload(OtlpConfig::default(), None, "");
        telemetry.reload(exporting_config(), None, "");
        telemetry.turn_finished(&finished, at(5));
        assert!(telemetry.take_batch().0.spans.is_empty());
    }

    #[tokio::test]
    async fn flush_posts_each_signal_and_pauses_on_failure() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let mut paths = Vec::new();
            for _ in 0..2 {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut buf = vec![0u8; 65536];
                let n = socket.read(&mut buf).await.unwrap();
                let request = String::from_utf8_lossy(&buf[..n]).to_string();
                paths.push(request.lines().next().unwrap_or_default().to_string());
                let status = if request.contains("/v1/traces") { "200 OK" } else { "500 Internal Server Error" };
                let reply = format!("HTTP/1.1 {status}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
                socket.write_all(reply.as_bytes()).await.unwrap();
            }
            paths
        });
        let mut config = OtlpConfig { enabled: true, ..Default::default() };
        config.endpoints.insert(OtlpSignal::Traces, format!("http://127.0.0.1:{port}/v1/traces"));
        config.endpoints.insert(OtlpSignal::Metrics, format!("http://127.0.0.1:{port}/v1/metrics"));
        let telemetry = NookTelemetry::new();
        telemetry.reload(config, None, "1.0.0");
        telemetry.scheduled_run_finished(ScheduledRunStatus::Succeeded, None, None, Utc::now());
        telemetry.flush().await;
        let paths = server.await.unwrap();
        assert!(paths.iter().any(|p| p.starts_with("POST /v1/traces")));
        assert!(paths.iter().any(|p| p.starts_with("POST /v1/metrics")));
        let s = telemetry.lock();
        assert!(!s.buffer.is_paused(OtlpSignal::Traces, Utc::now()));
        assert!(s.buffer.is_paused(OtlpSignal::Metrics, Utc::now()));
    }
}
