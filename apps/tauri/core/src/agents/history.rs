//! Eerdere sessies, tokengebruik en accounts van Claude Code, Codex, Gemini CLI en Antigravity (`AgentHistory` op de
//! Mac). Leest alleen hun eigen bestanden op deze computer (`~/.claude`, `~/.codex`, `~/.gemini`), en een transcript
//! alleen opnieuw als het veranderd is.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::profiles::AgentProfile;
use super::text::{clip, first_line};
use super::transcript::{blocks_text, clean_antigravity_prompt, gemini_text, is_typed_prompt};
use super::AgentKind;

/// Tokens uit een transcript. `cache_read` is gelezen uit de cache: goedkoop, maar telt mee voor de limieten.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenTally {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

impl TokenTally {
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_read + self.cache_write
    }
}

impl std::ops::AddAssign for TokenTally {
    fn add_assign(&mut self, o: Self) {
        self.input += o.input;
        self.output += o.output;
        self.cache_read += o.cache_read;
        self.cache_write += o.cache_write;
    }
}

/// "845k", "1,2M".
pub fn format_tokens(count: u64) -> String {
    match count {
        0..=999 => count.to_string(),
        1_000..=99_999 => format!("{:.1}k", count as f64 / 1_000.0).replace('.', ","),
        100_000..=999_999 => format!("{}k", count / 1_000),
        _ => format!("{:.1}M", count as f64 / 1_000_000.0).replace('.', ","),
    }
}

/// Een afgeronde (of nog lopende) sessie, uit het transcript dat de agent zelf bewaart.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PastSession {
    pub agent: AgentKind,
    pub session_id: String,
    pub title: String,
    pub cwd: String,
    /// De map waar de sessie het laatst werkte (na een `cd`); leeg als hij `cwd` nooit verliet.
    pub last_cwd: String,
    pub branch: String,
    pub model: String,
    pub started: DateTime<Utc>,
    pub ended: DateTime<Utc>,
    pub prompts: u32,
    pub tokens: TokenTally,
    pub last_prompt: String,
    pub last_reply: String,
    pub profile_id: String,
    pub path: String,
}

impl PastSession {
    pub fn id(&self) -> String {
        format!("{}:{}", self.agent.id(), self.session_id)
    }

    fn new(agent: AgentKind, session_id: String) -> Self {
        Self {
            agent,
            session_id,
            title: String::new(),
            cwd: String::new(),
            last_cwd: String::new(),
            branch: String::new(),
            model: String::new(),
            started: DateTime::<Utc>::MAX_UTC,
            ended: DateTime::<Utc>::MIN_UTC,
            prompts: 0,
            tokens: TokenTally::default(),
            last_prompt: String::new(),
            last_reply: String::new(),
            profile_id: String::new(),
            path: String::new(),
        }
    }

    fn stamp(&mut self, when: DateTime<Utc>) {
        self.started = self.started.min(when);
        self.ended = self.ended.max(when);
    }

    fn finish(mut self) -> Self {
        self.title = first_line(&self.title, 90);
        self.last_prompt = clip(&self.last_prompt, 4_000);
        self.last_reply = clip(&self.last_reply, 12_000);
        self
    }

    /// Waar verder te gaan: de map waar de sessie eindigde, tenzij die weg is (dan de map waar hij begon).
    pub fn resume_folder(&self) -> String {
        for candidate in [&self.last_cwd, &self.cwd] {
            if !candidate.is_empty() && crate::workspace::paths::verdict(candidate) == crate::workspace::paths::Verdict::Ok {
                return candidate.clone();
            }
        }
        self.cwd.clone()
    }

    /// De argumenten om verder te gaan waar je bleef.
    pub fn resume_arguments(&self) -> Vec<String> {
        match self.agent {
            AgentKind::Codex => vec!["resume".into(), self.session_id.clone()],
            AgentKind::Opencode => vec!["--session".into(), self.session_id.clone()],
            _ => vec!["--resume".into(), self.session_id.clone()],
        }
    }
}

/// Met welk account een agent is ingelogd, uit zijn eigen instellingen.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentAccount {
    pub agent: AgentKind,
    /// E-mailadres, of "API-sleutel".
    pub name: String,
    pub organization: String,
    pub plan: String,
}

/// Gebruik per account over vandaag en deze week.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSummary {
    pub today: TokenTally,
    pub week: TokenTally,
    pub sessions_today: u32,
    pub sessions_week: u32,
    /// Tokens per dag over de laatste 7 dagen, oudste eerst.
    pub per_day: Vec<(NaiveDate, u64)>,
}

/// Een account zoals de scan het nodig heeft.
#[derive(Debug, Clone)]
pub struct ProfileHome {
    pub id: String,
    pub kind: AgentKind,
    pub path: PathBuf,
    pub is_default: bool,
    /// Logt in met een API-sleutel uit Nooks kluis (Claude Code).
    pub api_key: bool,
}

impl ProfileHome {
    pub fn from_profile(p: &AgentProfile, has_key: bool) -> Self {
        Self { id: p.id.clone(), kind: p.kind, path: p.home_path(), is_default: p.is_default(), api_key: p.uses_api_key() && has_key }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryResult {
    pub sessions: Vec<PastSession>,
    pub accounts: BTreeMap<String, AgentAccount>,
    pub usage: BTreeMap<String, UsageSummary>,
    pub installed: Vec<AgentKind>,
    pub executables: BTreeMap<String, String>,
}

#[derive(Clone)]
struct UsageEntry {
    key: String,
    date: DateTime<Utc>,
    tokens: TokenTally,
}

#[derive(Clone, Default)]
struct Parsed {
    session: Option<PastSession>,
    entries: Vec<UsageEntry>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct CacheKey {
    modified: SystemTime,
    size: u64,
}

const DAYS: i64 = 30;
const MAX_FILES: usize = 400;

/// Leest de bestanden. Bewaart per transcript wat het al las.
#[derive(Default)]
pub struct HistoryScanner {
    cache: HashMap<PathBuf, (CacheKey, Parsed)>,
}

fn attributes(path: &Path) -> Option<CacheKey> {
    let meta = std::fs::metadata(path).ok()?;
    Some(CacheKey { modified: meta.modified().ok()?, size: meta.len() })
}

fn parse_date(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s).ok().map(|d| d.with_timezone(&Utc))
}

fn int(v: Option<&Value>) -> u64 {
    v.and_then(|v| v.as_u64().or_else(|| v.as_f64().map(|f| f.max(0.0) as u64))).unwrap_or(0)
}

fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

impl HistoryScanner {
    /// `own_folder`: Nooks eigen werkmap (het Claude Code-brein): die gesprekken staan niet in de lijst.
    pub fn scan(&mut self, homes: &[ProfileHome], own_folder: &str) -> HistoryResult {
        let since = SystemTime::now() - std::time::Duration::from_secs((DAYS * 86_400) as u64);
        let mut installed: HashSet<AgentKind> = HashSet::new();
        let mut files: Vec<(PathBuf, AgentKind, String, CacheKey)> = vec![];
        let mut seen = HashSet::new();
        for home in homes {
            if !home.path.exists() || !seen.insert(home.path.clone()) {
                continue;
            }
            installed.insert(home.kind);
            let found = match home.kind {
                AgentKind::Claude => claude_files(&home.path, since),
                AgentKind::Codex => codex_files(&home.path),
                AgentKind::Gemini => gemini_files(&home.path, since),
                AgentKind::Antigravity => antigravity_files(&home.path, since),
                // Over ACP: hun geschiedenis komt van de agent zelf, niet uit bestanden.
                _ => vec![],
            };
            files.extend(found.into_iter().map(|(p, k)| (p, home.kind, home.id.clone(), k)));
        }
        files.sort_by_key(|f| std::cmp::Reverse(f.3.modified));
        files.truncate(MAX_FILES);

        let summaries = antigravity_summaries(homes);
        let mut fresh = HashMap::new();
        let mut parsed_all: Vec<(String, Parsed)> = vec![];
        for (path, agent, profile, key) in files {
            let mut parsed = match self.cache.get(&path) {
                Some((k, p)) if *k == key => p.clone(),
                _ => match agent {
                    AgentKind::Claude => parse_claude(&path),
                    AgentKind::Codex => parse_codex(&path),
                    AgentKind::Gemini => parse_gemini(&path),
                    AgentKind::Antigravity => parse_antigravity(&path, &summaries),
                    _ => Parsed::default(),
                },
            };
            if let Some(s) = parsed.session.as_mut() {
                s.profile_id = profile.clone();
                s.path = path.to_string_lossy().into_owned();
            }
            fresh.insert(path, (key, parsed.clone()));
            parsed_all.push((profile, parsed));
        }
        self.cache = fresh;

        let mut sessions: Vec<PastSession> =
            parsed_all.iter().filter_map(|(_, p)| p.session.clone()).filter(|s| s.prompts > 0 && s.cwd != own_folder).collect();
        sessions.sort_by_key(|s| std::cmp::Reverse(s.ended));

        let mut usage = BTreeMap::new();
        for home in homes.iter().filter(|h| h.path.exists()) {
            let mine: Vec<&Parsed> = parsed_all.iter().filter(|(p, _)| p == &home.id).map(|(_, p)| p).collect();
            usage.insert(home.id.clone(), summarize(&mine, own_folder));
        }
        let executables: BTreeMap<String, String> = AgentKind::ALL
            .into_iter()
            .filter_map(|k| super::find_executable(k).map(|p| (k.id().to_string(), p.to_string_lossy().into_owned())))
            .collect();
        for k in AgentKind::ALL {
            if executables.contains_key(k.id()) {
                installed.insert(k);
            }
        }
        let mut installed: Vec<AgentKind> = installed.into_iter().collect();
        installed.sort();
        HistoryResult { sessions, accounts: read_accounts(homes), usage, installed, executables }
    }
}

fn summarize(parsed: &[&Parsed], own_folder: &str) -> UsageSummary {
    let today = Local::now().date_naive();
    let week_start = today - Duration::days(6);
    let local_day = |d: &DateTime<Utc>| d.with_timezone(&Local).date_naive();
    let mut summary = UsageSummary::default();
    let mut by_day: HashMap<NaiveDate, u64> = HashMap::new();
    let mut seen = HashSet::new();
    for file in parsed {
        for entry in &file.entries {
            let day = local_day(&entry.date);
            if day < week_start || !seen.insert(entry.key.clone()) {
                continue;
            }
            *by_day.entry(day).or_default() += entry.tokens.total();
            summary.week += entry.tokens;
            if day == today {
                summary.today += entry.tokens;
            }
        }
        if let Some(session) = file.session.as_ref().filter(|s| s.prompts > 0 && s.cwd != own_folder) {
            let day = local_day(&session.ended);
            if day >= week_start {
                summary.sessions_week += 1;
            }
            if day == today {
                summary.sessions_today += 1;
            }
        }
    }
    summary.per_day = (0..7).map(|o| week_start + Duration::days(o)).map(|d| (d, by_day.get(&d).copied().unwrap_or(0))).collect();
    summary
}

// MARK: Bestanden

/// `~/.claude/projects/<map>/<sessie>.jsonl`
fn claude_files(home: &Path, since: SystemTime) -> Vec<(PathBuf, CacheKey)> {
    let mut result = vec![];
    let Ok(projects) = std::fs::read_dir(home.join("projects")) else { return result };
    for project in projects.flatten() {
        let p = project.path();
        if attributes(&p).is_some_and(|k| k.modified < since) {
            continue;
        }
        let Ok(files) = std::fs::read_dir(&p) else { continue };
        for f in files.flatten() {
            let path = f.path();
            if path.extension().is_some_and(|e| e == "jsonl") {
                if let Some(k) = attributes(&path).filter(|k| k.modified >= since) {
                    result.push((path, k));
                }
            }
        }
    }
    result
}

/// `~/.codex/sessions/JJJJ/MM/DD/rollout-*.jsonl`, alleen mappen van de laatste dagen.
fn codex_files(home: &Path) -> Vec<(PathBuf, CacheKey)> {
    let root = home.join("sessions");
    let mut result = vec![];
    let mut seen = HashSet::new();
    let now = Local::now().date_naive();
    for offset in -1..=DAYS {
        let day = now - Duration::days(offset);
        let rel = format!("{:04}/{:02}/{:02}", day.year(), day.month(), day.day());
        if !seen.insert(rel.clone()) {
            continue;
        }
        let dir = root.join(&rel);
        let Ok(files) = std::fs::read_dir(&dir) else { continue };
        for f in files.flatten() {
            let name = f.file_name().to_string_lossy().into_owned();
            if name.starts_with("rollout-") && name.ends_with(".jsonl") {
                let path = f.path();
                if let Some(k) = attributes(&path) {
                    result.push((path, k));
                }
            }
        }
    }
    result
}

/// `~/.gemini/tmp/<project>/chats/session-*.json`
fn gemini_files(home: &Path, since: SystemTime) -> Vec<(PathBuf, CacheKey)> {
    let mut result = vec![];
    let Ok(projects) = std::fs::read_dir(home.join("tmp")) else { return result };
    for project in projects.flatten() {
        let Ok(files) = std::fs::read_dir(project.path().join("chats")) else { continue };
        for f in files.flatten() {
            let path = f.path();
            if path.extension().is_some_and(|e| e == "json") {
                if let Some(k) = attributes(&path).filter(|k| k.modified >= since) {
                    result.push((path, k));
                }
            }
        }
    }
    result
}

fn antigravity_root(home: &Path) -> PathBuf {
    if home.ends_with("antigravity") {
        home.to_path_buf()
    } else {
        home.join("antigravity")
    }
}

/// `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`
fn antigravity_files(home: &Path, since: SystemTime) -> Vec<(PathBuf, CacheKey)> {
    let mut result = vec![];
    let Ok(conversations) = std::fs::read_dir(antigravity_root(home).join("brain")) else { return result };
    for conv in conversations.flatten() {
        let path = conv.path().join(".system_generated").join("logs").join("transcript.jsonl");
        if let Some(k) = attributes(&path).filter(|k| k.modified >= since) {
            result.push((path, k));
        }
    }
    result
}

/// Titel en map van Antigravity-gesprekken uit `conversation_summaries.db`.
fn antigravity_summaries(homes: &[ProfileHome]) -> HashMap<String, (String, String)> {
    let mut result = HashMap::new();
    for home in homes.iter().filter(|h| h.kind == AgentKind::Antigravity) {
        let db = antigravity_root(&home.path).join("conversation_summaries.db");
        if !db.exists() {
            continue;
        }
        let Ok(conn) = rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) else { continue };
        let Ok(mut stmt) = conn.prepare("SELECT conversation_id, title, workspace_uris FROM conversation_summaries") else { continue };
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            ))
        });
        let Ok(rows) = rows else { continue };
        for (id, title, uris) in rows.flatten() {
            let first = serde_json::from_str::<Vec<String>>(&uris).ok().and_then(|l| l.into_iter().next()).unwrap_or_default();
            let cwd = first.strip_prefix("file://").map(percent_decode).unwrap_or(first);
            result.insert(id, (title, cwd));
        }
    }
    result
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn for_each_line(path: &Path, mut body: impl FnMut(&[u8])) -> bool {
    let Ok(data) = std::fs::read(path) else { return false };
    for line in data.split(|b| *b == b'\n') {
        if !line.is_empty() {
            body(line);
        }
    }
    true
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

fn file_modified(path: &Path) -> DateTime<Utc> {
    std::fs::metadata(path).and_then(|m| m.modified()).map(DateTime::<Utc>::from).unwrap_or_else(|_| Utc::now())
}

fn parse_gemini(path: &Path) -> Parsed {
    let Some(root) = std::fs::read(path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) else { return Parsed::default() };
    let Some(messages) = root.get("messages").and_then(Value::as_array) else { return Parsed::default() };
    // De map staat niet in de chat; nieuwere versies bewaren hem naast de chats in `.project_root`.
    let project_root = path.parent().and_then(Path::parent).map(|p| p.join(".project_root"));
    let cwd = project_root.and_then(|p| std::fs::read_to_string(p).ok()).map(|s| s.trim().to_string()).unwrap_or_default();
    let modified = file_modified(path);
    let sid = root.get("sessionId").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| stem(path));
    let mut session = PastSession::new(AgentKind::Gemini, sid);
    session.cwd = cwd;
    session.started = root.get("startTime").and_then(Value::as_str).and_then(parse_date).unwrap_or(modified);
    session.ended = root.get("lastUpdated").and_then(Value::as_str).and_then(parse_date).unwrap_or(modified);
    let mut entries = vec![];
    for message in messages {
        let text = gemini_text(message.get("content"));
        match s(message, "type") {
            "user" if !text.is_empty() => {
                session.prompts += 1;
                session.last_prompt = text.clone();
                if session.title.is_empty() {
                    session.title = text;
                }
            }
            "gemini" => {
                if !text.is_empty() {
                    session.last_reply = text;
                }
                if !s(message, "model").is_empty() {
                    session.model = s(message, "model").into();
                }
                if let Some(raw) = message.get("tokens") {
                    // Gemini telt gecachete tokens in zijn invoer mee; apart houden zoals bij de andere agents.
                    let cached = int(raw.get("cached"));
                    let tally = TokenTally {
                        input: int(raw.get("input")).saturating_sub(cached),
                        output: int(raw.get("output")) + int(raw.get("thoughts")),
                        cache_read: cached,
                        cache_write: 0,
                    };
                    session.tokens += tally;
                    let when = message.get("timestamp").and_then(Value::as_str).and_then(parse_date).unwrap_or(session.ended);
                    let id = message.get("id").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| entries.len().to_string());
                    entries.push(UsageEntry { key: format!("gemini:{}:{id}", session.session_id), date: when, tokens: tally });
                }
            }
            _ => {}
        }
    }
    Parsed { session: Some(session.finish()), entries }
}

fn stem(path: &Path) -> String {
    path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

fn parse_antigravity(path: &Path, summaries: &HashMap<String, (String, String)>) -> Parsed {
    // .../brain/<gesprek-id>/.system_generated/logs/transcript.jsonl
    let sid = path.ancestors().nth(3).and_then(Path::file_name).map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
    let mut session = PastSession::new(AgentKind::Antigravity, sid.clone());
    if let Some((title, cwd)) = summaries.get(&sid) {
        session.title = title.clone();
        session.cwd = cwd.clone();
    }
    let mut entries = vec![];
    let ok = for_each_line(path, |line| {
        let planner = contains(line, br#""PLANNER_RESPONSE""#);
        let user = !planner && contains(line, br#""USER_INPUT""#);
        if !planner && !user {
            return;
        }
        let Ok(object) = serde_json::from_slice::<Value>(line) else { return };
        let stamp = object.get("created_at").and_then(Value::as_str).and_then(parse_date);
        if let Some(stamp) = stamp {
            session.stamp(stamp);
        }
        if user {
            if let Some(content) = object.get("content").and_then(Value::as_str) {
                let text = clean_antigravity_prompt(content);
                if text.is_empty() {
                    return;
                }
                session.prompts += 1;
                session.last_prompt = text.clone();
                if session.title.is_empty() {
                    session.title = text;
                }
            }
            return;
        }
        if let Some(content) = object.get("content").and_then(Value::as_str) {
            if !content.trim().is_empty() {
                session.last_reply = content.trim().into();
            }
        } else if session.last_reply.is_empty() {
            let thinking = s(&object, "thinking").trim();
            if !thinking.is_empty() {
                session.last_reply = thinking.into();
            }
        }
        if session.cwd.is_empty() {
            for call in object.get("tool_calls").and_then(Value::as_array).into_iter().flatten() {
                let raw = call.get("args").map(|a| if s(a, "Cwd").is_empty() { s(a, "cwd") } else { s(a, "Cwd") }).unwrap_or("");
                let clean = raw.trim_matches(|c: char| "\"'\n\r\t ".contains(c));
                if !clean.is_empty() {
                    session.cwd = clean.into();
                    break;
                }
            }
        }
        let (input, output, cache) =
            (int(object.get("input_tokens")), int(object.get("output_tokens")), int(object.get("cache_read_tokens")));
        if input + output + cache > 0 {
            let tally = TokenTally { input, output, cache_read: cache, cache_write: 0 };
            session.tokens += tally;
            let step = object.get("step_index").and_then(Value::as_u64).unwrap_or(entries.len() as u64);
            entries.push(UsageEntry { key: format!("antigravity:{sid}:{step}"), date: stamp.unwrap_or(session.ended), tokens: tally });
        }
    });
    if !ok {
        return Parsed::default();
    }
    let fallback = file_modified(path);
    if session.started == DateTime::<Utc>::MAX_UTC {
        session.started = if session.ended > DateTime::<Utc>::MIN_UTC { session.ended } else { fallback };
    }
    if session.ended == DateTime::<Utc>::MIN_UTC {
        session.ended = session.started;
    }
    if session.prompts == 0 && session.title.is_empty() && session.last_reply.is_empty() {
        return Parsed { session: None, entries };
    }
    Parsed { session: Some(session.finish()), entries }
}

fn parse_claude(path: &Path) -> Parsed {
    let mut session = PastSession::new(AgentKind::Claude, stem(path));
    let mut summary_title = String::new();
    let mut entries = vec![];
    let mut seen_usage = HashSet::new();
    let ok = for_each_line(path, |line| {
        if summary_title.is_empty() && contains(line, br#""type":"summary""#) {
            if let Ok(o) = serde_json::from_slice::<Value>(line) {
                if s(&o, "type") == "summary" {
                    summary_title = s(&o, "summary").into();
                    return;
                }
            }
        }
        let assistant = contains(line, br#""type":"assistant""#);
        let user = !assistant && contains(line, br#""type":"user""#) && !contains(line, br#""tool_result""#);
        if !assistant && !user {
            return;
        }
        let Ok(object) = serde_json::from_slice::<Value>(line) else { return };
        let when = object.get("timestamp").and_then(Value::as_str).and_then(parse_date);
        if let Some(w) = when {
            session.stamp(w);
        }
        let cwd = s(&object, "cwd");
        if !cwd.is_empty() {
            if session.cwd.is_empty() {
                session.cwd = cwd.into();
            }
            session.last_cwd = if cwd == session.cwd { String::new() } else { cwd.into() };
        }
        let branch = s(&object, "gitBranch");
        if !branch.is_empty() && branch != "HEAD" {
            session.branch = branch.into();
        }
        let empty = Value::Null;
        let message = object.get("message").unwrap_or(&empty);
        if assistant {
            let model = s(message, "model");
            if !model.is_empty() && !model.starts_with('<') {
                session.model = model.into();
            }
            let text = blocks_text(message.get("content"));
            if !text.is_empty() {
                session.last_reply = text;
            }
            if let Some(raw) = message.get("usage") {
                let id = format!("{}:{}", s(message, "id"), s(&object, "requestId"));
                // Claude Code schrijft per blok een regel, elk met hetzelfde gebruik.
                if id != ":" && !seen_usage.insert(id.clone()) {
                    return;
                }
                let tokens = TokenTally {
                    input: int(raw.get("input_tokens")),
                    output: int(raw.get("output_tokens")),
                    cache_read: int(raw.get("cache_read_input_tokens")),
                    cache_write: int(raw.get("cache_creation_input_tokens")),
                };
                session.tokens += tokens;
                let key = if id == ":" { uuid::Uuid::new_v4().to_string() } else { id };
                entries.push(UsageEntry { key, date: when.unwrap_or(session.ended), tokens });
            }
        } else {
            if object.get("isMeta").and_then(Value::as_bool) == Some(true)
                || object.get("isSidechain").and_then(Value::as_bool) == Some(true)
            {
                return;
            }
            let text = blocks_text(message.get("content"));
            if !is_typed_prompt(&text) {
                return;
            }
            session.prompts += 1;
            session.last_prompt = text.clone();
            if session.title.is_empty() {
                session.title = text;
            }
        }
    });
    if !ok || session.ended == DateTime::<Utc>::MIN_UTC {
        return Parsed { session: None, entries };
    }
    if !summary_title.is_empty() {
        session.title = summary_title;
    }
    Parsed { session: Some(session.finish()), entries }
}

fn parse_codex(path: &Path) -> Parsed {
    // rollout-2026-10-14T10-12-33-<uuid>.jsonl: de uuid is wat `codex resume` verwacht.
    let base = stem(path);
    let fallback = if base.chars().count() > 36 { base.chars().skip(base.chars().count() - 36).collect() } else { base };
    let mut session = PastSession::new(AgentKind::Codex, fallback);
    let mut entries = vec![];
    let mut previous = TokenTally::default();
    let markers: [&[u8]; 5] = [b"session_meta", b"turn_context", b"user_message", b"agent_message", b"token_count"];
    let ok = for_each_line(path, |line| {
        if !markers.iter().any(|m| contains(line, m)) {
            return;
        }
        let Ok(object) = serde_json::from_slice::<Value>(line) else { return };
        let when = object.get("timestamp").and_then(Value::as_str).and_then(parse_date);
        if let Some(w) = when {
            session.stamp(w);
        }
        let empty = Value::Null;
        let payload = object.get("payload").unwrap_or(&empty);
        match s(&object, "type") {
            "session_meta" => {
                if !s(payload, "id").is_empty() {
                    session.session_id = s(payload, "id").into();
                }
                if let Some(cwd) = payload.get("cwd").and_then(Value::as_str) {
                    session.cwd = cwd.into();
                }
                if let Some(b) = payload.pointer("/git/branch").and_then(Value::as_str) {
                    session.branch = b.into();
                }
            }
            "turn_context" => {
                if let Some(m) = payload.get("model").and_then(Value::as_str) {
                    session.model = m.into();
                }
                if session.cwd.is_empty() {
                    session.cwd = s(payload, "cwd").into();
                }
            }
            "event_msg" => match s(payload, "type") {
                "user_message" => {
                    let text = s(payload, "message");
                    if text.trim().is_empty() {
                        return;
                    }
                    session.prompts += 1;
                    session.last_prompt = text.into();
                    if session.title.is_empty() {
                        session.title = text.into();
                    }
                }
                "agent_message" => {
                    if !s(payload, "message").is_empty() {
                        session.last_reply = s(payload, "message").into();
                    }
                }
                "token_count" => {
                    // Het totaal van de sessie tot nu; het verschil met de vorige regel is het nieuwe gebruik.
                    let Some(total) = payload.pointer("/info/total_token_usage") else { return };
                    let cached = int(total.get("cached_input_tokens"));
                    let current = TokenTally {
                        input: int(total.get("input_tokens")).saturating_sub(cached),
                        output: int(total.get("output_tokens")),
                        cache_read: cached,
                        cache_write: 0,
                    };
                    if current.total() <= previous.total() {
                        return;
                    }
                    let delta = TokenTally {
                        input: current.input.saturating_sub(previous.input),
                        output: current.output.saturating_sub(previous.output),
                        cache_read: current.cache_read.saturating_sub(previous.cache_read),
                        cache_write: 0,
                    };
                    previous = current;
                    session.tokens = current;
                    entries.push(UsageEntry {
                        key: format!("{}:{}", session.session_id, current.total()),
                        date: when.unwrap_or(session.ended),
                        tokens: delta,
                    });
                }
                _ => {}
            },
            _ => {}
        }
    });
    if !ok || session.ended == DateTime::<Utc>::MIN_UTC {
        return Parsed { session: None, entries };
    }
    Parsed { session: Some(session.finish()), entries }
}

// MARK: Accounts

pub fn read_accounts(homes: &[ProfileHome]) -> BTreeMap<String, AgentAccount> {
    let mut accounts = BTreeMap::new();
    for home in homes.iter().filter(|h| h.path.exists()) {
        let account = match home.kind {
            AgentKind::Claude if home.api_key => {
                Some(AgentAccount { agent: AgentKind::Claude, name: "API-sleutel".into(), organization: String::new(), plan: "API".into() })
            }
            AgentKind::Claude => claude_account(&home.path, home.is_default),
            AgentKind::Codex => codex_account(&home.path),
            AgentKind::Gemini => gemini_account(&home.path),
            AgentKind::Antigravity => antigravity_account(&home.path),
            kind => acp_account(kind, &home.path),
        };
        if let Some(a) = account {
            accounts.insert(home.id.clone(), a);
        }
    }
    accounts
}

fn read_json(path: &Path) -> Option<Value> {
    std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok())
}

fn account(agent: AgentKind, name: impl Into<String>, organization: impl Into<String>, plan: impl Into<String>) -> AgentAccount {
    AgentAccount { agent, name: name.into(), organization: organization.into(), plan: plan.into() }
}

/// `~/.claude.json` (of in de accountmap bij `CLAUDE_CONFIG_DIR`): met welk account Claude Code ingelogd is.
fn claude_account(config_home: &Path, is_default: bool) -> Option<AgentAccount> {
    let mut candidates = vec![config_home.join(".claude.json"), config_home.join(".config.json")];
    if is_default && std::env::var_os("CLAUDE_CONFIG_DIR").is_none() {
        candidates.insert(0, super::home_dir().join(".claude.json"));
    }
    for file in candidates {
        let Some(root) = read_json(&file) else { continue };
        if let Some(oauth) = root.get("oauthAccount") {
            let email = oauth.get("emailAddress").or_else(|| oauth.get("displayName")).and_then(Value::as_str).unwrap_or("Claude-account");
            let org = s(oauth, "organizationName");
            // "<email>'s Organization" zegt niets extra's.
            let clean = if org.contains(email) || org.ends_with("'s Organization") { "" } else { org };
            let plan = ["subscriptionType", "planType", "rateLimitTier"]
                .iter()
                .map(|k| s(oauth, k))
                .find(|v| !v.is_empty())
                .map(plan_name)
                .unwrap_or_default();
            return Some(account(AgentKind::Claude, email, clean, plan));
        }
        if root.get("primaryApiKey").is_some() {
            return Some(account(AgentKind::Claude, "API-sleutel", "", ""));
        }
    }
    None
}

/// `~/.codex/auth.json`: ingelogd met ChatGPT (e-mail en abonnement in het id-token) of met een API-sleutel.
fn codex_account(home: &Path) -> Option<AgentAccount> {
    let root = read_json(&home.join("auth.json"))?;
    if let Some(claims) = root.pointer("/tokens/id_token").and_then(Value::as_str).and_then(jwt_claims) {
        let plan =
            claims.pointer("/https:~1~1api.openai.com~1auth/chatgpt_plan_type").and_then(Value::as_str).map(plan_name).unwrap_or_default();
        return Some(account(AgentKind::Codex, claims.get("email").and_then(Value::as_str).unwrap_or("ChatGPT-account"), "", plan));
    }
    if root.get("OPENAI_API_KEY").and_then(Value::as_str).is_some_and(|k| !k.is_empty()) {
        return Some(account(AgentKind::Codex, "API-sleutel", "", ""));
    }
    None
}

fn antigravity_account(home: &Path) -> Option<AgentAccount> {
    if !home.join("antigravity").exists() && !home.join("config").join("hooks.json").exists() {
        return None;
    }
    Some(match gemini_account(home) {
        Some(g) => account(AgentKind::Antigravity, g.name, "", g.plan),
        None => account(AgentKind::Antigravity, "Google-account", "", ""),
    })
}

/// `~/.gemini/google_accounts.json` (actief Google-account) en `settings.json` (de inlogmethode).
fn gemini_account(home: &Path) -> Option<AgentAccount> {
    let settings = read_json(&home.join("settings.json")).unwrap_or(Value::Null);
    let auth = settings
        .pointer("/security/auth/selectedType")
        .and_then(Value::as_str)
        .or_else(|| settings.get("selectedAuthType").and_then(Value::as_str))
        .unwrap_or("");
    let accounts = read_json(&home.join("google_accounts.json")).unwrap_or(Value::Null);
    if let Some(email) = accounts.get("active").and_then(Value::as_str).filter(|e| !e.is_empty()) {
        return Some(account(AgentKind::Gemini, email, "", if auth == "vertex-ai" { "Vertex AI" } else { "Google-account" }));
    }
    match auth {
        "gemini-api-key" => Some(account(AgentKind::Gemini, "API-sleutel", "", "")),
        "vertex-ai" => Some(account(AgentKind::Gemini, "Vertex AI", "", "")),
        _ => None,
    }
}

/// OpenCode, Cursor en Grok: ingelogd als hun inlogbestand er is.
fn acp_account(kind: AgentKind, home: &Path) -> Option<AgentAccount> {
    let file = if kind == AgentKind::Cursor { home.join("cli-config.json") } else { home.join("auth.json") };
    let Some(root) = read_json(&file) else {
        // Grok bewaart zijn inlog elders in zijn map: de map zelf betekent dat hij is ingesteld.
        return (kind == AgentKind::Grok).then(|| account(kind, kind.name(), "", ""));
    };
    match kind {
        AgentKind::Cursor => {
            let auth = root.get("authInfo")?;
            Some(account(kind, auth.get("email").and_then(Value::as_str).unwrap_or(kind.name()), "", ""))
        }
        AgentKind::Opencode => {
            let mut providers: Vec<&String> = root.as_object()?.keys().collect();
            providers.sort();
            (!providers.is_empty()).then(|| account(kind, providers.iter().map(|p| p.as_str()).collect::<Vec<_>>().join(", "), "", ""))
        }
        _ => {
            let email = root.get("email").and_then(Value::as_str).or_else(|| root.pointer("/user/email").and_then(Value::as_str));
            Some(account(kind, email.unwrap_or(kind.name()), "", ""))
        }
    }
}

/// Alleen het middendeel van een JWT. Niets wordt gecontroleerd of verstuurd.
fn jwt_claims(token: &str) -> Option<Value> {
    let part = token.split('.').nth(1)?;
    let bytes = base64_url_decode(part)?;
    serde_json::from_slice(&bytes).ok()
}

pub fn base64_url_decode(input: &str) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut buffer = 0u32;
    let mut bits = 0;
    for c in input.chars() {
        let v = match c {
            'A'..='Z' => c as u32 - 'A' as u32,
            'a'..='z' => c as u32 - 'a' as u32 + 26,
            '0'..='9' => c as u32 - '0' as u32 + 52,
            '-' | '+' => 62,
            '_' | '/' => 63,
            '=' => break,
            _ => return None,
        };
        buffer = (buffer << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// Gewone base64 (met `=`), voor data-URL's.
pub fn base64_encode(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |a, (i, b)| a | (*b as u32) << (16 - 8 * i));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(T[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// "max" → "Max", "claude_max_20x" → "Max 20x", "plus" → "Plus".
pub fn plan_name(raw: &str) -> String {
    raw.to_lowercase()
        .replace("default_", "")
        .replace("claude_", "")
        .split(['_', '-'])
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Voor tests: een datum als UTC.
pub fn utc(y: i32, m: u32, d: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(y, m, d, 12, 0, 0).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-history-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn reads_claude_sessions_and_usage() {
        let home = temp();
        let project = home.join("projects").join("-w-app");
        std::fs::create_dir_all(&project).unwrap();
        let now = Utc::now().to_rfc3339();
        let lines = [
            format!(r#"{{"type":"user","timestamp":"{now}","cwd":"/w/app","gitBranch":"main","message":{{"content":"Maak een login"}}}}"#),
            format!(
                r#"{{"type":"assistant","timestamp":"{now}","requestId":"r1","message":{{"id":"m1","model":"claude-x","content":[{{"type":"text","text":"Gedaan"}}],"usage":{{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100}}}}}}"#
            ),
            format!(
                r#"{{"type":"assistant","timestamp":"{now}","requestId":"r1","message":{{"id":"m1","content":[],"usage":{{"input_tokens":10,"output_tokens":5}}}}}}"#
            ),
        ];
        std::fs::write(project.join("abc.jsonl"), lines.join("\n")).unwrap();
        std::fs::write(
            home.join(".claude.json"),
            r#"{"oauthAccount":{"emailAddress":"a@b.nl","organizationName":"a@b.nl's Organization","subscriptionType":"claude_max_20x"}}"#,
        )
        .unwrap();
        let homes =
            vec![ProfileHome { id: "claude-test".into(), kind: AgentKind::Claude, path: home.clone(), is_default: false, api_key: false }];
        let result = HistoryScanner::default().scan(&homes, "/nook");
        let s = &result.sessions[0];
        assert_eq!(
            (s.session_id.as_str(), s.title.as_str(), s.branch.as_str(), s.model.as_str()),
            ("abc", "Maak een login", "main", "claude-x")
        );
        assert_eq!(s.tokens.total(), 115, "dubbele regels tellen één keer");
        assert_eq!(result.usage["claude-test"].today.total(), 115);
        let account = &result.accounts["claude-test"];
        assert_eq!((account.name.as_str(), account.organization.as_str(), account.plan.as_str()), ("a@b.nl", "", "Max 20x"));
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn reads_codex_rollouts() {
        let home = temp();
        let day = Local::now().date_naive();
        let dir = home.join("sessions").join(format!("{:04}/{:02}/{:02}", day.year(), day.month(), day.day()));
        std::fs::create_dir_all(&dir).unwrap();
        let now = Utc::now().to_rfc3339();
        let lines = [
            format!(
                r#"{{"timestamp":"{now}","type":"session_meta","payload":{{"id":"019a-uuid","cwd":"/w/x","git":{{"branch":"dev"}}}}}}"#
            ),
            format!(r#"{{"timestamp":"{now}","type":"event_msg","payload":{{"type":"user_message","message":"Repareer de build"}}}}"#),
            format!(
                r#"{{"timestamp":"{now}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":50,"cached_input_tokens":20,"output_tokens":5}}}}}}}}"#
            ),
            format!(r#"{{"timestamp":"{now}","type":"event_msg","payload":{{"type":"agent_message","message":"Klaar"}}}}"#),
        ];
        std::fs::write(dir.join("rollout-2026-x.jsonl"), lines.join("\n")).unwrap();
        let payload = r#"{"email":"c@d.nl","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}"#;
        let token = format!("x.{}.y", base64_url(payload.as_bytes()));
        std::fs::write(home.join("auth.json"), format!(r#"{{"tokens":{{"id_token":"{token}"}}}}"#)).unwrap();
        let homes = vec![ProfileHome { id: "codex".into(), kind: AgentKind::Codex, path: home.clone(), is_default: true, api_key: false }];
        let result = HistoryScanner::default().scan(&homes, "/nook");
        let s = &result.sessions[0];
        assert_eq!((s.session_id.as_str(), s.cwd.as_str(), s.last_reply.as_str()), ("019a-uuid", "/w/x", "Klaar"));
        assert_eq!(s.tokens, TokenTally { input: 30, output: 5, cache_read: 20, cache_write: 0 });
        assert_eq!(result.accounts["codex"].plan, "Plus");
        let _ = std::fs::remove_dir_all(home);
    }

    fn base64_url(bytes: &[u8]) -> String {
        const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let n = chunk.iter().enumerate().fold(0u32, |a, (i, b)| a | (*b as u32) << (16 - 8 * i));
            for i in 0..=chunk.len() {
                out.push(T[((n >> (18 - 6 * i)) & 63) as usize] as char);
            }
        }
        out
    }

    #[test]
    fn helpers() {
        assert_eq!(plan_name("claude_max_20x"), "Max 20x");
        assert_eq!(format_tokens(845_000), "845k");
        assert_eq!(format_tokens(1_200_000), "1,2M");
        assert_eq!(format_tokens(12_300), "12,3k");
        assert_eq!(percent_decode("/a%20b"), "/a b");
    }
}
