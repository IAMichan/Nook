//! OpenTelemetry OTLP/HTTP JSON export (`OTLPConfig`, `OTLPPayload`, `NookTelemetry` on the Mac).
//!
//! Off by default and free when off. When enabled (either via Settings › Maintenance › OpenTelemetry export or standard
//! `OTEL_EXPORTER_OTLP_*` environment variables), Nook builds OTLP/HTTP JSON payloads by hand — no SDK dependency —
//! carrying only privacy-safe resource attributes (`service.name`, `service.version`, `os.type`), never prompts,
//! answers, file contents, usernames, hostnames, or paths.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use chrono::{DateTime, Utc};
use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use rand::RngExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Keychain / `SecretStore` account where OTLP headers are stored (`OTLPSettings.headersAccount` on the Mac).
pub const HEADERS_SECRET_ACCOUNT: &str = "otlp.headers";

/// Standard OpenTelemetry environment variable names.
pub const BASE_ENDPOINT_ENV: &str = "OTEL_EXPORTER_OTLP_ENDPOINT";
pub const HEADERS_ENV: &str = "OTEL_EXPORTER_OTLP_HEADERS";
pub const PROTOCOL_ENV: &str = "OTEL_EXPORTER_OTLP_PROTOCOL";
pub const SDK_DISABLED_ENV: &str = "OTEL_SDK_DISABLED";

/// Instrumentation scope attached to every exported record.
pub const SCOPE_NAME: &str = "nook";

/// Characters percent-encoded when serializing `OTEL_EXPORTER_OTLP_HEADERS` (`key=value,key2=value2`).
const HEADER_ENCODE_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~')
    .remove(b':')
    .remove(b'/')
    .remove(b'+');

/// One OpenTelemetry signal, each with its own OTLP/HTTP endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OtlpSignal {
    Traces,
    Metrics,
    Logs,
}

impl OtlpSignal {
    pub const ALL: [Self; 3] = [Self::Traces, Self::Metrics, Self::Logs];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Traces => "traces",
            Self::Metrics => "metrics",
            Self::Logs => "logs",
        }
    }

    /// The path appended to a base endpoint (`http://localhost:4318` + `/v1/traces`).
    pub fn path(self) -> &'static str {
        match self {
            Self::Traces => "/v1/traces",
            Self::Metrics => "/v1/metrics",
            Self::Logs => "/v1/logs",
        }
    }

    pub fn endpoint_env(self) -> &'static str {
        match self {
            Self::Traces => "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
            Self::Metrics => "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
            Self::Logs => "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
        }
    }

    pub fn exporter_env(self) -> &'static str {
        match self {
            Self::Traces => "OTEL_TRACES_EXPORTER",
            Self::Metrics => "OTEL_METRICS_EXPORTER",
            Self::Logs => "OTEL_LOGS_EXPORTER",
        }
    }

    pub fn root_key(self) -> &'static str {
        match self {
            Self::Traces => "resourceSpans",
            Self::Metrics => "resourceMetrics",
            Self::Logs => "resourceLogs",
        }
    }

    pub fn scope_key(self) -> &'static str {
        match self {
            Self::Traces => "scopeSpans",
            Self::Metrics => "scopeMetrics",
            Self::Logs => "scopeLogs",
        }
    }
}

/// Wire encoding choice passed on to coding agents (`OTLPProtocol` on the Mac).
/// Nook's own export always speaks `http/json`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum OtlpProtocol {
    #[default]
    #[serde(rename = "http/protobuf")]
    HttpProtobuf,
    #[serde(rename = "http/json")]
    HttpJson,
}

impl OtlpProtocol {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HttpProtobuf => "http/protobuf",
            Self::HttpJson => "http/json",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "http/protobuf" => Some(Self::HttpProtobuf),
            "http/json" => Some(Self::HttpJson),
            _ => None,
        }
    }
}

/// Settings persisted in `settings.json` under `telemetry` (never contains header secrets).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TelemetrySettings {
    /// Master switch for Nook's Settings-configured OTLP export.
    pub enabled: bool,
    pub traces_endpoint: String,
    pub metrics_endpoint: String,
    pub logs_endpoint: String,
    pub protocol: OtlpProtocol,
}

impl Default for TelemetrySettings {
    fn default() -> Self {
        Self {
            enabled: false,
            traces_endpoint: String::new(),
            metrics_endpoint: String::new(),
            logs_endpoint: String::new(),
            protocol: OtlpProtocol::HttpProtobuf,
        }
    }
}

impl TelemetrySettings {
    pub fn endpoint_for(&self, signal: OtlpSignal) -> &str {
        match signal {
            OtlpSignal::Traces => &self.traces_endpoint,
            OtlpSignal::Metrics => &self.metrics_endpoint,
            OtlpSignal::Logs => &self.logs_endpoint,
        }
    }
}

/// Where an effective OTLP value came from, so Settings can show "Set by environment (VAR)".
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "variable", rename_all = "camelCase")]
pub enum OtlpSource {
    Settings,
    Environment(String),
}

/// One HTTP header sent with every OTLP export (for example `Authorization: Bearer …`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OtlpHeader {
    pub name: String,
    pub value: String,
}

impl OtlpHeader {
    pub fn new(name: impl Into<String>, value: impl Into<String>) -> Self {
        Self { name: name.into(), value: value.into() }
    }

    /// Convenience constructor for a Bearer token authorization header.
    pub fn bearer(token: &str) -> Self {
        Self::new("Authorization", format!("Bearer {}", token.trim()))
    }

    /// Parses `key=value,key2=value2` (the standard `OTEL_EXPORTER_OTLP_HEADERS` format): entries split on commas,
    /// each on its first `=`, trimmed and percent-decoded. Entries with missing `=`, empty names, or non-ASCII /
    /// whitespace header names are dropped.
    pub fn parse(text: &str) -> Vec<Self> {
        text.split(',')
            .filter_map(|entry| {
                let (raw_name, raw_value) = entry.split_once('=')?;
                let name = percent_decode_str(raw_name.trim()).decode_utf8_lossy().trim().to_string();
                if name.is_empty() || !name.bytes().all(|b| b.is_ascii() && !b.is_ascii_whitespace() && !b.is_ascii_control()) {
                    return None;
                }
                let value = percent_decode_str(raw_value.trim()).decode_utf8_lossy().trim().to_string();
                Some(Self { name, value })
            })
            .collect()
    }

    /// Formats headers back into `key=value,key2=value2` with commas, equals signs, and percent signs encoded.
    pub fn format(headers: &[Self]) -> String {
        headers
            .iter()
            .map(|h| {
                let name = utf8_percent_encode(&h.name, HEADER_ENCODE_SET);
                let value = utf8_percent_encode(&h.value, HEADER_ENCODE_SET);
                format!("{name}={value}")
            })
            .collect::<Vec<_>>()
            .join(",")
    }
}

/// Effective configuration after merging `TelemetrySettings`, saved headers, and `OTEL_EXPORTER_OTLP_*` env vars.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OtlpConfig {
    pub enabled: bool,
    pub endpoints: BTreeMap<OtlpSignal, String>,
    pub endpoint_sources: BTreeMap<OtlpSignal, OtlpSource>,
    pub headers: Vec<OtlpHeader>,
    pub headers_source: OtlpSource,
    pub protocol: OtlpProtocol,
    pub protocol_source: OtlpSource,
    pub sdk_disabled: bool,
}

impl Default for OtlpConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            endpoints: BTreeMap::new(),
            endpoint_sources: BTreeMap::new(),
            headers: Vec::new(),
            headers_source: OtlpSource::Settings,
            protocol: OtlpProtocol::HttpProtobuf,
            protocol_source: OtlpSource::Settings,
            sdk_disabled: false,
        }
    }
}

impl OtlpConfig {
    /// Resolves effective OTLP configuration from saved settings, saved keychain headers, and environment variables.
    ///
    /// Precedence per signal matches macOS `OTLPResolver`:
    /// 1. `OTEL_<SIGNAL>_EXPORTER=none` disables the signal completely.
    /// 2. `OTEL_EXPORTER_OTLP_<SIGNAL>_ENDPOINT` (exact URL).
    /// 3. `OTEL_EXPORTER_OTLP_ENDPOINT` + `/v1/<signal>`.
    /// 4. Saved setting endpoint (active when `saved.enabled` is true).
    pub fn resolve<S: AsRef<str>>(
        saved: &TelemetrySettings,
        saved_headers: &str,
        env: &BTreeMap<String, S>,
    ) -> Self {
        let env_val = |key: &str| -> Option<String> {
            env.get(key)
                .map(|v| v.as_ref().trim().to_string())
                .filter(|v| !v.is_empty())
        };

        let mut config = Self { enabled: saved.enabled, ..Self::default() };
        let base = env_val(BASE_ENDPOINT_ENV).and_then(|v| validate_http_url(&v));

        for signal in OtlpSignal::ALL {
            if env_val(signal.exporter_env()).is_some_and(|v| v.eq_ignore_ascii_case("none")) {
                continue;
            }
            if let Some(url) = env_val(signal.endpoint_env()).and_then(|v| validate_http_url(&v)) {
                config.endpoints.insert(signal, url);
                config.endpoint_sources.insert(signal, OtlpSource::Environment(signal.endpoint_env().into()));
            } else if let Some(ref b) = base {
                let trimmed = b.trim_end_matches('/');
                config.endpoints.insert(signal, format!("{trimmed}{}", signal.path()));
                config.endpoint_sources.insert(signal, OtlpSource::Environment(BASE_ENDPOINT_ENV.into()));
            } else if saved.enabled {
                if let Some(url) = validate_http_url(saved.endpoint_for(signal)) {
                    config.endpoints.insert(signal, url);
                    config.endpoint_sources.insert(signal, OtlpSource::Settings);
                }
            }
        }

        if let Some(raw_headers) = env_val(HEADERS_ENV) {
            config.headers = OtlpHeader::parse(&raw_headers);
            config.headers_source = OtlpSource::Environment(HEADERS_ENV.into());
        } else {
            config.headers = OtlpHeader::parse(saved_headers);
            config.headers_source = OtlpSource::Settings;
        }

        if let Some(choice) = env_val(PROTOCOL_ENV).and_then(|v| OtlpProtocol::parse(&v)) {
            config.protocol = choice;
            config.protocol_source = OtlpSource::Environment(PROTOCOL_ENV.into());
        } else {
            config.protocol = saved.protocol;
            config.protocol_source = OtlpSource::Settings;
        }

        config.sdk_disabled = env_val(SDK_DISABLED_ENV).is_some_and(|v| v.eq_ignore_ascii_case("true"));
        config
    }

    /// Resolves using the current process environment.
    pub fn resolve_process(saved: &TelemetrySettings, saved_headers: &str) -> Self {
        let env: BTreeMap<String, String> = std::env::vars().collect();
        Self::resolve(saved, saved_headers, &env)
    }

    pub fn is_empty(&self) -> bool {
        self.endpoints.is_empty()
    }

    /// Whether Nook should actively emit its own telemetry records.
    pub fn is_exporting(&self) -> bool {
        !self.is_empty() && !self.sdk_disabled
    }

    pub fn endpoint(&self, signal: OtlpSignal) -> Option<&str> {
        self.endpoints.get(&signal).map(String::as_str)
    }

    /// Common base URL when every configured endpoint ends in its signal's `/v1/<signal>` path and shares the same
    /// base — needed by agents that accept a single base endpoint.
    pub fn base_endpoint(&self) -> Option<String> {
        if self.endpoints.is_empty() {
            return None;
        }
        let mut bases = BTreeSet::new();
        for (&signal, url) in &self.endpoints {
            let trimmed = url.trim_end_matches('/');
            let base = trimmed.strip_suffix(signal.path())?;
            if base.is_empty() {
                return None;
            }
            bases.insert(base.to_string());
        }
        if bases.len() == 1 {
            bases.into_iter().next()
        } else {
            None
        }
    }

    pub fn headers_variable(&self) -> String {
        OtlpHeader::format(&self.headers)
    }
}

/// Validates an HTTP or HTTPS URL with a non-empty host; returns the normalized string or `None`.
pub fn validate_http_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let parsed = url::Url::parse(trimmed).ok()?;
    let scheme = parsed.scheme();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    if parsed.host_str().is_none_or(|h| h.is_empty()) {
        return None;
    }
    Some(trimmed.to_string())
}

// MARK: Payload types

/// An OTLP `AnyValue` attribute value.
#[derive(Debug, Clone, PartialEq)]
pub enum OtlpValue {
    String(String),
    Int(i64),
    Double(f64),
    Bool(bool),
}

impl OtlpValue {
    pub fn to_json(&self) -> Value {
        match self {
            Self::String(v) => json!({ "stringValue": v }),
            Self::Int(v) => json!({ "intValue": v.to_string() }),
            Self::Double(v) => json!({ "doubleValue": v }),
            Self::Bool(v) => json!({ "boolValue": v }),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct OtlpSpan {
    pub trace_id: String,
    pub span_id: String,
    pub name: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub attributes: BTreeMap<String, OtlpValue>,
    /// `false` sets `STATUS_CODE_ERROR` (2) with optional `status_message`.
    pub ok: bool,
    pub status_message: Option<String>,
}

/// A monotonic delta sum metric data point (turns, tokens, seconds, task runs).
#[derive(Debug, Clone, PartialEq)]
pub struct OtlpSum {
    pub name: String,
    pub unit: String,
    pub description: String,
    pub attributes: BTreeMap<String, OtlpValue>,
    pub value: f64,
    /// When `true`, serialized as `asInt` (decimal string); otherwise `asDouble`.
    pub is_integer: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OtlpSeverity {
    Info = 9,
    Warn = 13,
    Error = 17,
}

impl OtlpSeverity {
    pub fn text(self) -> &'static str {
        match self {
            Self::Info => "INFO",
            Self::Warn => "WARN",
            Self::Error => "ERROR",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct OtlpLogRecord {
    pub time: DateTime<Utc>,
    pub severity: OtlpSeverity,
    pub body: String,
    pub attributes: BTreeMap<String, OtlpValue>,
    pub trace_id: Option<String>,
    pub span_id: Option<String>,
}

/// Privacy-safe resource attributes: service name, version, OS type, and SDK marker.
/// Never includes username, hostname, IP address, file paths, or prompts.
pub fn privacy_safe_resource(version: &str) -> BTreeMap<String, OtlpValue> {
    let os_type = match std::env::consts::OS {
        "macos" => "darwin",
        other => other,
    };
    let mut attrs = BTreeMap::new();
    attrs.insert("service.name".into(), OtlpValue::String("nook".into()));
    attrs.insert("service.version".into(), OtlpValue::String(version.into()));
    attrs.insert("os.type".into(), OtlpValue::String(os_type.into()));
    attrs.insert("telemetry.sdk.name".into(), OtlpValue::String(SCOPE_NAME.into()));
    attrs
}

/// Hand-encoded OTLP/HTTP JSON payloads matching the OTLP JSON protobuf mapping.
pub struct OtlpPayload;

impl OtlpPayload {
    /// An empty export payload for connection testing (`{"resourceSpans":[]}`, etc.).
    pub fn empty(signal: OtlpSignal) -> Vec<u8> {
        let mut obj = serde_json::Map::new();
        obj.insert(signal.root_key().into(), Value::Array(Vec::new()));
        serde_json::to_vec(&Value::Object(obj)).unwrap_or_else(|_| b"{}".to_vec())
    }

    pub fn traces(spans: &[OtlpSpan], resource: &BTreeMap<String, OtlpValue>, version: &str) -> Vec<u8> {
        let records: Vec<Value> = spans
            .iter()
            .map(|span| {
                let end = if span.end < span.start { span.start } else { span.end };
                let mut status = serde_json::Map::new();
                status.insert("code".into(), json!(if span.ok { 1 } else { 2 }));
                if !span.ok {
                    if let Some(ref msg) = span.status_message {
                        if !msg.is_empty() {
                            status.insert("message".into(), json!(msg));
                        }
                    }
                }
                json!({
                    "traceId": span.trace_id,
                    "spanId": span.span_id,
                    "name": span.name,
                    "kind": 1,
                    "startTimeUnixNano": nanos(span.start),
                    "endTimeUnixNano": nanos(end),
                    "attributes": attributes_json(&span.attributes),
                    "status": Value::Object(status),
                })
            })
            .collect();
        wrap(OtlpSignal::Traces, resource, version, "spans", records)
    }

    pub fn metrics(
        sums: &[OtlpSum],
        resource: &BTreeMap<String, OtlpValue>,
        version: &str,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Vec<u8> {
        let end = if end < start { start } else { end };
        let mut order: Vec<&str> = Vec::new();
        let mut grouped: BTreeMap<&str, Vec<&OtlpSum>> = BTreeMap::new();
        for sum in sums {
            if !grouped.contains_key(sum.name.as_str()) {
                order.push(sum.name.as_str());
            }
            grouped.entry(sum.name.as_str()).or_default().push(sum);
        }
        let metrics: Vec<Value> = order
            .into_iter()
            .map(|name| {
                let group = &grouped[name];
                let points: Vec<Value> = group
                    .iter()
                    .map(|sum| {
                        let mut pt = serde_json::Map::new();
                        pt.insert("startTimeUnixNano".into(), json!(nanos(start)));
                        pt.insert("timeUnixNano".into(), json!(nanos(end)));
                        pt.insert("attributes".into(), Value::Array(attributes_json(&sum.attributes)));
                        if sum.is_integer {
                            pt.insert("asInt".into(), json!((sum.value.round() as i64).to_string()));
                        } else {
                            pt.insert("asDouble".into(), json!(sum.value));
                        }
                        Value::Object(pt)
                    })
                    .collect();
                json!({
                    "name": name,
                    "unit": group[0].unit,
                    "description": group[0].description,
                    "sum": {
                        "dataPoints": points,
                        "aggregationTemporality": 1,
                        "isMonotonic": true,
                    },
                })
            })
            .collect();
        wrap(OtlpSignal::Metrics, resource, version, "metrics", metrics)
    }

    pub fn logs(records: &[OtlpLogRecord], resource: &BTreeMap<String, OtlpValue>, version: &str) -> Vec<u8> {
        let items: Vec<Value> = records
            .iter()
            .map(|r| {
                let mut item = serde_json::Map::new();
                item.insert("timeUnixNano".into(), json!(nanos(r.time)));
                item.insert("observedTimeUnixNano".into(), json!(nanos(r.time)));
                item.insert("severityNumber".into(), json!(r.severity as i32));
                item.insert("severityText".into(), json!(r.severity.text()));
                item.insert("body".into(), json!({ "stringValue": r.body }));
                item.insert("attributes".into(), Value::Array(attributes_json(&r.attributes)));
                if let Some(ref tid) = r.trace_id {
                    item.insert("traceId".into(), json!(tid));
                }
                if let Some(ref sid) = r.span_id {
                    item.insert("spanId".into(), json!(sid));
                }
                Value::Object(item)
            })
            .collect();
        wrap(OtlpSignal::Logs, resource, version, "logRecords", items)
    }

    /// Generates a lowercase hex ID of `bytes` bytes (16 for traceId, 8 for spanId), never all zeros.
    pub fn random_id(bytes: usize) -> String {
        let count = bytes.max(1);
        let mut rng = rand::rng();
        let mut buf = vec![0u8; count];
        loop {
            rng.fill(&mut buf[..]);
            if buf.iter().any(|&b| b != 0) {
                return buf.iter().map(|b| format!("{b:02x}")).collect();
            }
        }
    }
}

fn wrap(
    signal: OtlpSignal,
    resource: &BTreeMap<String, OtlpValue>,
    version: &str,
    records_key: &str,
    records: Vec<Value>,
) -> Vec<u8> {
    let mut scope_obj = serde_json::Map::new();
    scope_obj.insert("scope".into(), json!({ "name": SCOPE_NAME, "version": version }));
    scope_obj.insert(records_key.into(), Value::Array(records));

    let mut entry = serde_json::Map::new();
    entry.insert("resource".into(), json!({ "attributes": attributes_json(resource) }));
    entry.insert(signal.scope_key().into(), Value::Array(vec![Value::Object(scope_obj)]));

    let mut root = serde_json::Map::new();
    root.insert(signal.root_key().into(), Value::Array(vec![Value::Object(entry)]));
    serde_json::to_vec(&Value::Object(root)).unwrap_or_else(|_| b"{}".to_vec())
}

fn attributes_json(values: &BTreeMap<String, OtlpValue>) -> Vec<Value> {
    values
        .iter()
        .map(|(k, v)| json!({ "key": k, "value": v.to_json() }))
        .collect()
}

pub fn nanos(time: DateTime<Utc>) -> String {
    let secs = time.timestamp().max(0) as u128;
    let sub = u128::from(time.timestamp_subsec_nanos());
    (secs * 1_000_000_000 + sub).to_string()
}

// MARK: Exporter

/// Outcome of a connection test against an OTLP/HTTP receiver.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum OtlpTestResult {
    Ok { status: u16 },
    Rejected { status: u16 },
    Unreachable { message: String },
}

/// Asynchronous OTLP/HTTP JSON exporter. Redirects are disabled so auth headers never leak across hosts.
#[derive(Clone)]
pub struct OtlpExporter {
    client: reqwest::Client,
}

impl Default for OtlpExporter {
    fn default() -> Self {
        Self::new()
    }
}

impl OtlpExporter {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .connect_timeout(Duration::from_secs(5))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("otlp reqwest client");
        Self { client }
    }

    /// Sends an empty export of `signal` to `url` with `headers` and reports HTTP acceptance, rejection, or error.
    pub async fn test_connection(&self, signal: OtlpSignal, url: &str, headers: &[OtlpHeader]) -> OtlpTestResult {
        let Some(valid) = validate_http_url(url) else {
            return OtlpTestResult::Unreachable { message: "invalid http or https URL".into() };
        };
        let body = OtlpPayload::empty(signal);
        match self.post_json(&valid, body, headers).await {
            Ok(status) if (200..300).contains(&status) => OtlpTestResult::Ok { status },
            Ok(status) => OtlpTestResult::Rejected { status },
            Err(message) => OtlpTestResult::Unreachable { message },
        }
    }

    /// Emits a single span to the configured traces endpoint. Returns `Ok(None)` when tracing is disabled.
    pub async fn emit_span(&self, config: &OtlpConfig, span: OtlpSpan, version: &str) -> Result<Option<u16>, String> {
        if !config.is_exporting() {
            return Ok(None);
        }
        let Some(url) = config.endpoint(OtlpSignal::Traces) else {
            return Ok(None);
        };
        let resource = privacy_safe_resource(version);
        let body = OtlpPayload::traces(&[span], &resource, version);
        let status = self.post_json(url, body, &config.headers).await?;
        Ok(Some(status))
    }

    /// Emits a single delta sum metric to the configured metrics endpoint. Returns `Ok(None)` when disabled.
    pub async fn emit_metric(
        &self,
        config: &OtlpConfig,
        metric: OtlpSum,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        version: &str,
    ) -> Result<Option<u16>, String> {
        if !config.is_exporting() {
            return Ok(None);
        }
        let Some(url) = config.endpoint(OtlpSignal::Metrics) else {
            return Ok(None);
        };
        let resource = privacy_safe_resource(version);
        let body = OtlpPayload::metrics(&[metric], &resource, version, start, end);
        let status = self.post_json(url, body, &config.headers).await?;
        Ok(Some(status))
    }

    /// Emits a single log record to the configured logs endpoint. Returns `Ok(None)` when disabled.
    pub async fn emit_log(&self, config: &OtlpConfig, record: OtlpLogRecord, version: &str) -> Result<Option<u16>, String> {
        if !config.is_exporting() {
            return Ok(None);
        }
        let Some(url) = config.endpoint(OtlpSignal::Logs) else {
            return Ok(None);
        };
        let resource = privacy_safe_resource(version);
        let body = OtlpPayload::logs(&[record], &resource, version);
        let status = self.post_json(url, body, &config.headers).await?;
        Ok(Some(status))
    }

    /// Posts an OTLP/HTTP JSON body with `headers` and returns the HTTP status (`NookTelemetry`'s batched export).
    pub async fn post(&self, url: &str, body: Vec<u8>, headers: &[OtlpHeader]) -> Result<u16, String> {
        self.post_json(url, body, headers).await
    }

    async fn post_json(&self, url: &str, body: Vec<u8>, headers: &[OtlpHeader]) -> Result<u16, String> {
        let mut req = self.client.post(url);
        for h in headers {
            req = req.header(&h.name, &h.value);
        }
        let resp = req
            .header("Content-Type", "application/json")
            .body(body)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        Ok(resp.status().as_u16())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[test]
    fn validates_http_and_https_urls() {
        assert_eq!(validate_http_url("http://localhost:4318/v1/traces").as_deref(), Some("http://localhost:4318/v1/traces"));
        assert_eq!(validate_http_url("  https://otlp.example.com/v1/metrics  ").as_deref(), Some("https://otlp.example.com/v1/metrics"));
        assert_eq!(validate_http_url(""), None);
        assert_eq!(validate_http_url("ftp://localhost:4318"), None);
        assert_eq!(validate_http_url("file:///tmp/out"), None);
        assert_eq!(validate_http_url("not a url"), None);
        assert_eq!(validate_http_url("http://"), None);
    }

    #[test]
    fn parses_and_formats_otlp_headers() {
        let parsed = OtlpHeader::parse("Authorization=Bearer%20secret%2Ctoken, x-api-key = abc=123 , badentry, =noname");
        assert_eq!(
            parsed,
            vec![
                OtlpHeader::new("Authorization", "Bearer secret,token"),
                OtlpHeader::new("x-api-key", "abc=123"),
            ]
        );
        let formatted = OtlpHeader::format(&parsed);
        assert_eq!(OtlpHeader::parse(&formatted), parsed);
        assert_eq!(OtlpHeader::bearer("  tok_123 "), OtlpHeader::new("Authorization", "Bearer tok_123"));
    }

    #[test]
    fn resolves_env_precedence_and_enabled_toggle() {
        let saved = TelemetrySettings {
            enabled: false,
            traces_endpoint: "http://saved:4318/v1/traces".into(),
            metrics_endpoint: "http://saved:4318/v1/metrics".into(),
            logs_endpoint: String::new(),
            protocol: OtlpProtocol::HttpJson,
        };
        let empty_env: BTreeMap<String, String> = BTreeMap::new();

        // Disabled saved settings produce an empty non-exporting config.
        let off = OtlpConfig::resolve(&saved, "Authorization=Bearer saved", &empty_env);
        assert!(!off.is_exporting());
        assert!(off.is_empty());

        // Enabling saved settings activates saved endpoints & protocol.
        let mut enabled_saved = saved.clone();
        enabled_saved.enabled = true;
        let on = OtlpConfig::resolve(&enabled_saved, "Authorization=Bearer saved", &empty_env);
        assert!(on.is_exporting());
        assert_eq!(on.endpoint(OtlpSignal::Traces), Some("http://saved:4318/v1/traces"));
        assert_eq!(on.endpoint(OtlpSignal::Metrics), Some("http://saved:4318/v1/metrics"));
        assert_eq!(on.endpoint(OtlpSignal::Logs), None);
        assert_eq!(on.base_endpoint().as_deref(), Some("http://saved:4318"));
        assert_eq!(on.protocol, OtlpProtocol::HttpJson);
        assert_eq!(on.headers, vec![OtlpHeader::new("Authorization", "Bearer saved")]);

        // Environment overrides base, signal, headers, protocol, and exporter=none.
        let mut env: BTreeMap<String, String> = BTreeMap::new();
        env.insert(BASE_ENDPOINT_ENV.into(), "https://collector.local:4318/".into());
        env.insert(OtlpSignal::Traces.endpoint_env().into(), "https://traces.custom/ingest".into());
        env.insert(OtlpSignal::Logs.exporter_env().into(), "none".into());
        env.insert(HEADERS_ENV.into(), "x-env=yes".into());
        env.insert(PROTOCOL_ENV.into(), "http/protobuf".into());

        let from_env = OtlpConfig::resolve(&saved, "Authorization=Bearer saved", &env);
        assert!(from_env.is_exporting());
        assert_eq!(from_env.endpoint(OtlpSignal::Traces), Some("https://traces.custom/ingest"));
        assert_eq!(
            from_env.endpoint_sources.get(&OtlpSignal::Traces),
            Some(&OtlpSource::Environment("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT".into()))
        );
        assert_eq!(from_env.endpoint(OtlpSignal::Metrics), Some("https://collector.local:4318/v1/metrics"));
        assert_eq!(from_env.endpoint(OtlpSignal::Logs), None);
        assert_eq!(from_env.base_endpoint(), None);
        assert_eq!(from_env.headers, vec![OtlpHeader::new("x-env", "yes")]);
        assert_eq!(from_env.protocol, OtlpProtocol::HttpProtobuf);

        // OTEL_SDK_DISABLED=true stops export even with env endpoints.
        env.insert(SDK_DISABLED_ENV.into(), "true".into());
        let disabled = OtlpConfig::resolve(&enabled_saved, "", &env);
        assert!(disabled.sdk_disabled);
        assert!(!disabled.is_exporting());
    }

    #[test]
    fn builds_valid_otlp_json_payloads_with_privacy_safe_resource() {
        let resource = privacy_safe_resource("1.2.3");
        assert_eq!(resource.get("service.name"), Some(&OtlpValue::String("nook".into())));
        assert_eq!(resource.get("service.version"), Some(&OtlpValue::String("1.2.3".into())));
        assert!(resource.contains_key("os.type"));
        assert!(!resource.contains_key("host.name"));
        assert!(!resource.contains_key("user.name"));

        // Empty payloads
        let empty_traces: Value = serde_json::from_slice(&OtlpPayload::empty(OtlpSignal::Traces)).unwrap();
        assert_eq!(empty_traces, json!({ "resourceSpans": [] }));

        // Span payload
        let start = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        let end = DateTime::from_timestamp(1_700_000_002, 500_000_000).unwrap();
        let mut attrs = BTreeMap::new();
        attrs.insert("nook.agent".into(), OtlpValue::String("claude".into()));
        attrs.insert("nook.tokens".into(), OtlpValue::Int(420));
        let span = OtlpSpan {
            trace_id: OtlpPayload::random_id(16),
            span_id: OtlpPayload::random_id(8),
            name: "nook.agent.turn".into(),
            start,
            end,
            attributes: attrs,
            ok: false,
            status_message: Some("timeout".into()),
        };
        assert_eq!(span.trace_id.len(), 32);
        assert_eq!(span.span_id.len(), 16);
        let trace_json: Value = serde_json::from_slice(&OtlpPayload::traces(&[span], &resource, "1.2.3")).unwrap();
        let s0 = &trace_json["resourceSpans"][0]["scopeSpans"][0]["spans"][0];
        assert_eq!(s0["name"], "nook.agent.turn");
        assert_eq!(s0["kind"], 1);
        assert_eq!(s0["status"]["code"], 2);
        assert_eq!(s0["status"]["message"], "timeout");
        assert_eq!(s0["startTimeUnixNano"], "1700000000000000000");
        assert_eq!(s0["endTimeUnixNano"], "1700000002500000000");

        // Metric payload grouping
        let sums = vec![
            OtlpSum {
                name: "nook.agent.turns".into(),
                unit: "{turn}".into(),
                description: "Agent turns".into(),
                attributes: BTreeMap::new(),
                value: 3.0,
                is_integer: true,
            },
            OtlpSum {
                name: "nook.agent.duration".into(),
                unit: "s".into(),
                description: "Turn duration".into(),
                attributes: BTreeMap::new(),
                value: 2.5,
                is_integer: false,
            },
        ];
        let metric_json: Value = serde_json::from_slice(&OtlpPayload::metrics(&sums, &resource, "1.2.3", start, end)).unwrap();
        let ms = metric_json["resourceMetrics"][0]["scopeMetrics"][0]["metrics"].as_array().unwrap();
        assert_eq!(ms.len(), 2);
        assert_eq!(ms[0]["sum"]["dataPoints"][0]["asInt"], "3");
        assert_eq!(ms[0]["sum"]["aggregationTemporality"], 1);
        assert_eq!(ms[1]["sum"]["dataPoints"][0]["asDouble"], 2.5);

        // Log payload
        let log = OtlpLogRecord {
            time: start,
            severity: OtlpSeverity::Warn,
            body: "turn finished".into(),
            attributes: BTreeMap::new(),
            trace_id: Some("0123456789abcdef0123456789abcdef".into()),
            span_id: None,
        };
        let log_json: Value = serde_json::from_slice(&OtlpPayload::logs(&[log], &resource, "1.2.3")).unwrap();
        let lr = &log_json["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0];
        assert_eq!(lr["severityNumber"], 13);
        assert_eq!(lr["severityText"], "WARN");
        assert_eq!(lr["body"]["stringValue"], "turn finished");
    }

    async fn spawn_one_shot_server(status_line: &'static str) -> (String, tokio::task::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 8192];
            let n = socket.read(&mut buf).await.unwrap();
            let req = String::from_utf8_lossy(&buf[..n]).into_owned();
            let resp = format!("{status_line}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}");
            socket.write_all(resp.as_bytes()).await.unwrap();
            req
        });
        (format!("http://127.0.0.1:{}", addr.port()), handle)
    }

    #[tokio::test]
    async fn exporter_tests_connection_and_emits_spans_and_metrics() {
        let exporter = OtlpExporter::new();

        // 200 OK with custom bearer header
        let (base, req_task) = spawn_one_shot_server("HTTP/1.1 200 OK").await;
        let headers = vec![OtlpHeader::bearer("tok_abc")];
        let res = exporter.test_connection(OtlpSignal::Traces, &format!("{base}/v1/traces"), &headers).await;
        assert_eq!(res, OtlpTestResult::Ok { status: 200 });
        let raw_req = req_task.await.unwrap();
        assert!(raw_req.contains("POST /v1/traces HTTP/1.1"));
        assert!(raw_req.to_ascii_lowercase().contains("authorization: bearer tok_abc"));
        assert!(raw_req.contains("{\"resourceSpans\":[]}"));

        // 401 Rejected
        let (base401, _) = spawn_one_shot_server("HTTP/1.1 401 Unauthorized").await;
        let res401 = exporter.test_connection(OtlpSignal::Metrics, &format!("{base401}/v1/metrics"), &[]).await;
        assert_eq!(res401, OtlpTestResult::Rejected { status: 401 });

        // 302 Redirect is NOT followed (returned as Rejected so auth headers never leak)
        let (base302, _) = spawn_one_shot_server("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/steal").await;
        let res302 = exporter.test_connection(OtlpSignal::Logs, &format!("{base302}/v1/logs"), &headers).await;
        assert_eq!(res302, OtlpTestResult::Rejected { status: 302 });

        // emit_span and emit_metric against local receiver
        let (base_span, span_task) = spawn_one_shot_server("HTTP/1.1 200 OK").await;
        let (base_metric, metric_task) = spawn_one_shot_server("HTTP/1.1 200 OK").await;
        let saved = TelemetrySettings {
            enabled: true,
            traces_endpoint: format!("{base_span}/v1/traces"),
            metrics_endpoint: format!("{base_metric}/v1/metrics"),
            logs_endpoint: String::new(),
            protocol: OtlpProtocol::HttpJson,
        };
        let cfg = OtlpConfig::resolve(&saved, "x-team=nook", &BTreeMap::<String, String>::new());
        let now = Utc::now();
        let span = OtlpSpan {
            trace_id: OtlpPayload::random_id(16),
            span_id: OtlpPayload::random_id(8),
            name: "nook.app.launch".into(),
            start: now,
            end: now,
            attributes: BTreeMap::new(),
            ok: true,
            status_message: None,
        };
        assert_eq!(exporter.emit_span(&cfg, span, "1.0.0").await.unwrap(), Some(200));
        let span_req = span_task.await.unwrap();
        assert!(span_req.contains("nook.app.launch"));
        assert!(span_req.to_ascii_lowercase().contains("x-team: nook"));

        let sum = OtlpSum {
            name: "nook.agent.turns".into(),
            unit: "{turn}".into(),
            description: "Turns".into(),
            attributes: BTreeMap::new(),
            value: 1.0,
            is_integer: true,
        };
        assert_eq!(exporter.emit_metric(&cfg, sum, now, now, "1.0.0").await.unwrap(), Some(200));
        let metric_req = metric_task.await.unwrap();
        assert!(metric_req.contains("nook.agent.turns"));
    }
}
