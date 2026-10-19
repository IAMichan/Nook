//! De notities van de Notetaker: transcript, samenvatting, kernpunten en to-do's van een gesprek, en hoe het
//! transcript uit de twee opnames ontstaat (de microfoon ben jij, het geluid van de computer zijn "de anderen").
//! Zelfde regels als `NoteModels.swift` op de Mac (naar open-source code onder de MIT-licentie, © 2026 Louis Raillé).

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use chrono::{DateTime, Datelike, Local, Timelike, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::paths;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteSpeaker {
    pub id: String,
    pub name: String,
    /// Plek in de sprekerkleuren.
    pub color: usize,
    #[serde(default)]
    pub is_me: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteLine {
    pub id: String,
    pub speaker: String,
    /// Seconden vanaf het begin van de opname.
    pub start: f64,
    pub end: f64,
    pub text: String,
}

impl NoteLine {
    fn new(speaker: &str, start: f64, end: f64, text: &str) -> Self {
        Self { id: uuid::Uuid::new_v4().to_string(), speaker: speaker.into(), start, end, text: text.into() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteTodo {
    pub id: String,
    pub text: String,
    pub owner: Option<String>,
    pub due: Option<String>,
    #[serde(default)]
    pub done: bool,
}

impl NoteTodo {
    pub fn new(text: &str, owner: Option<String>, due: Option<String>) -> Self {
        Self { id: uuid::Uuid::new_v4().to_string(), text: text.into(), owner, due, done: false }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NoteStatus {
    Recording,
    Processing,
    Ready,
    Failed,
}

/// Een gesprek dat de Notetaker noteerde.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub title_edited: bool,
    pub start: DateTime<Utc>,
    pub end: Option<DateTime<Utc>>,
    /// De app die voor stond toen de opname begon ("Zoom", "Firefox").
    pub app: Option<String>,
    pub status: NoteStatus,
    #[serde(default)]
    pub speakers: Vec<NoteSpeaker>,
    #[serde(default)]
    pub lines: Vec<NoteLine>,
    pub summary: Option<String>,
    #[serde(default)]
    pub key_points: Vec<String>,
    #[serde(default)]
    pub todos: Vec<NoteTodo>,
    pub error: Option<String>,
    /// Of het geluid van de computer meeopgenomen werd (anders alleen de microfoon).
    #[serde(default)]
    pub system_audio: bool,
}

impl Note {
    pub fn new(title: &str, start: DateTime<Utc>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            title: title.into(),
            title_edited: false,
            start,
            end: None,
            app: None,
            status: NoteStatus::Recording,
            speakers: vec![],
            lines: vec![],
            summary: None,
            key_points: vec![],
            todos: vec![],
            error: None,
            system_audio: false,
        }
    }

    pub fn duration(&self) -> f64 {
        (self.end.unwrap_or_else(Utc::now) - self.start).num_milliseconds() as f64 / 1000.0
    }

    pub fn speaker(&self, id: &str) -> Option<&NoteSpeaker> {
        self.speakers.iter().find(|s| s.id == id)
    }

    /// Het deel van het praten per spreker, uit de lengte van hun regels.
    pub fn shares(&self) -> BTreeMap<String, f64> {
        let mut time: BTreeMap<String, f64> = BTreeMap::new();
        for line in &self.lines {
            *time.entry(line.speaker.clone()).or_default() += (line.end - line.start).max(0.1);
        }
        let total: f64 = time.values().sum();
        if total <= 0.0 {
            return BTreeMap::new();
        }
        time.into_iter().map(|(k, v)| (k, v / total)).collect()
    }
}

/// Een woord met zijn plek in de audio.
#[derive(Debug, Clone, PartialEq)]
pub struct TimedWord {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

/// Woorden verder uit elkaar dan dit beginnen een nieuwe regel.
pub const PAUSE: f64 = 1.4;
/// Een regel wordt nooit langer dan dit, zodat het transcript leesbaar blijft.
pub const MAX_LINE_SECONDS: f64 = 40.0;
pub const ME_ID: &str = "me";
pub const OTHERS_ID: &str = "others";

/// Opeenvolgende woorden van dezelfde spreker, dicht bij elkaar in tijd, vormen één regel.
pub fn lines(words: &[(&str, TimedWord)]) -> Vec<NoteLine> {
    let mut out: Vec<NoteLine> = Vec::new();
    for (speaker, word) in words {
        if let Some(last) = out.last_mut() {
            if last.speaker == *speaker && word.start - last.end < PAUSE && word.end - last.start < MAX_LINE_SECONDS {
                last.text.push(' ');
                last.text.push_str(&word.text);
                last.end = word.end;
                continue;
            }
        }
        out.push(NoteLine::new(speaker, word.start, word.end, &word.text));
    }
    out
}

pub fn tokens(s: &str) -> Vec<String> {
    s.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|t| !t.is_empty()).map(String::from).collect()
}

fn overlaps(a: &NoteLine, b: &NoteLine, margin: f64) -> bool {
    a.start < b.end + margin && b.start < a.end + margin
}

/// Zonder koptelefoon komen de stemmen van de anderen ook uit de luidsprekers in de microfoon. Een regel van jou
/// waarvan de opname van de anderen dezelfde woorden op hetzelfde moment heeft, is die echo.
pub fn removing_echo(mine: Vec<NoteLine>, others: &[NoteLine]) -> Vec<NoteLine> {
    mine.into_iter()
        .filter(|line| {
            let words = tokens(&line.text);
            if words.len() < 2 {
                let first = words.first().cloned().unwrap_or_default();
                return !others.iter().any(|o| overlaps(o, line, 0.8) && tokens(&o.text).contains(&first));
            }
            let near: Vec<String> = others.iter().filter(|o| overlaps(o, line, 1.5)).flat_map(|o| tokens(&o.text)).collect();
            if near.is_empty() {
                return true;
            }
            let pool: BTreeSet<&String> = near.iter().collect();
            let shared = words.iter().filter(|w| pool.contains(w)).count();
            (shared as f64) / (words.len() as f64) < 0.6
        })
        .collect()
}

/// Het hele transcript van de twee kanten: jouw regels zonder de echo van de anderen, op volgorde van tijd.
pub fn build(mine: &[TimedWord], others: &[TimedWord], me_name: &str, others_name: &str) -> (Vec<NoteSpeaker>, Vec<NoteLine>) {
    let my_lines = lines(&mine.iter().map(|w| (ME_ID, w.clone())).collect::<Vec<_>>());
    let their_lines = lines(&others.iter().map(|w| (OTHERS_ID, w.clone())).collect::<Vec<_>>());
    let mut all = removing_echo(my_lines, &their_lines);
    all.extend(their_lines);
    all.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut speakers = Vec::new();
    if all.iter().any(|l| l.speaker == ME_ID) {
        speakers.push(NoteSpeaker { id: ME_ID.into(), name: me_name.into(), color: 0, is_me: true });
    }
    if all.iter().any(|l| l.speaker == OTHERS_ID) {
        speakers.push(NoteSpeaker { id: OTHERS_ID.into(), name: others_name.into(), color: 1, is_me: false });
    }
    (speakers, all)
}

/// Woorden uit de segmenten van de herkenning, op hun plek in de opname: `offset` is waar het stuk begon.
pub fn words(segments: &[(String, f64, f64)], offset: f64) -> Vec<TimedWord> {
    segments
        .iter()
        .filter_map(|(text, start, duration)| {
            let text = text.trim();
            (!text.is_empty()).then(|| TimedWord { text: text.into(), start: offset + start, end: offset + start + duration.max(0.05) })
        })
        .collect()
}

/// Wat het brein krijgt om de notities te schrijven. Gevraagd als JSON, zodat de to-do's open punten kunnen worden.
pub const SUMMARY_INSTRUCTIONS: &str = r#"You write the notes of a meeting from its transcript. Each line is "Name: words".
Write in the language of the transcript. Invent nothing that was not said.
The transcript comes from speech recognition: a word that makes no sense was probably misheard, understand it from the context.
Reply ONLY with JSON, no code block, in this exact shape:
{"title": "a short title, 6 words at most", "summary": "2 to 4 sentences: what was decided and why", "key_points": ["up to 6 short points"], "todos": [{"text": "the task", "owner": "the person's name as written in the transcript, or null", "due": "the deadline as said, or null"}]}"#;

#[derive(Debug, Clone, PartialEq)]
pub struct Summary {
    pub title: Option<String>,
    pub summary: String,
    pub key_points: Vec<String>,
    pub todos: Vec<NoteTodo>,
}

/// Leest het JSON-antwoord van het model, ook in een codeblok of met tekst eromheen. `None` zonder JSON.
pub fn parse_summary(reply: &str) -> Option<Summary> {
    let (open, close) = (reply.find('{')?, reply.rfind('}')?);
    if open >= close {
        return None;
    }
    let json: Value = serde_json::from_str(&reply[open..=close]).ok()?;
    let summary = json.get("summary").and_then(Value::as_str).unwrap_or("").trim().to_string();
    let points: Vec<String> = json
        .get("key_points")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect();
    let field = |item: &Value, key: &str| -> Option<String> {
        item.get(key).and_then(Value::as_str).filter(|v| !v.is_empty() && v.to_lowercase() != "null").map(String::from)
    };
    let todos: Vec<NoteTodo> = json
        .get("todos")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| match item {
            Value::String(text) if !text.is_empty() => Some(NoteTodo::new(text, None, None)),
            Value::Object(_) => {
                let text = field(item, "text")?;
                Some(NoteTodo::new(&text, field(item, "owner"), field(item, "due")))
            }
            _ => None,
        })
        .collect();
    if summary.is_empty() && points.is_empty() && todos.is_empty() {
        return None;
    }
    let title = json.get("title").and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty()).map(String::from);
    Some(Summary { title, summary, key_points: points, todos })
}

/// Het transcript als platte tekst voor de samenvatting: "Naam: woorden" per regel.
pub fn plain_transcript(note: &Note) -> String {
    note.lines
        .iter()
        .map(|l| format!("{}: {}", note.speaker(&l.speaker).map(|s| s.name.as_str()).unwrap_or(&l.speaker), l.text))
        .collect::<Vec<_>>()
        .join("\n")
}

/// 75 → "1:15", 3725 → "1:02:05".
pub fn clock(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s % 3600) / 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

const WEEKDAYS: [&str; 7] = ["maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag"];
const MONTHS: [&str; 12] =
    ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus", "september", "oktober", "november", "december"];

/// "maandag 19 oktober 2026 om 14:05".
pub fn long_date(date: DateTime<Utc>) -> String {
    let local = date.with_timezone(&Local);
    format!(
        "{} {} {} {} om {}:{:02}",
        WEEKDAYS[local.weekday().num_days_from_monday() as usize],
        local.day(),
        MONTHS[local.month0() as usize],
        local.year(),
        local.hour(),
        local.minute()
    )
}

/// De notitie als Markdown: titel, datum, samenvatting, kernpunten, to-do's en dan het transcript.
pub fn markdown(note: &Note) -> String {
    let mut out = format!("# {}\n\n", note.title);
    let minutes = ((note.duration() / 60.0).round() as i64).max(1);
    out.push_str(&format!("_{} · {minutes} min_", long_date(note.start)));
    if !note.speakers.is_empty() {
        out.push_str(&format!("  \n_{}_", note.speakers.iter().map(|s| s.name.as_str()).collect::<Vec<_>>().join(", ")));
    }
    out.push_str("\n\n");
    if let Some(summary) = note.summary.as_ref().filter(|s| !s.is_empty()) {
        out.push_str(&format!("## Samenvatting\n\n{summary}\n\n"));
    }
    if !note.key_points.is_empty() {
        out.push_str(&format!("## Kernpunten\n\n{}\n\n", note.key_points.iter().map(|p| format!("- {p}")).collect::<Vec<_>>().join("\n")));
    }
    if !note.todos.is_empty() {
        let todos = note
            .todos
            .iter()
            .map(|t| {
                let mut line = format!("- [{}] {}", if t.done { "x" } else { " " }, t.text);
                let extra: Vec<&str> = [t.owner.as_deref(), t.due.as_deref()].into_iter().flatten().filter(|s| !s.is_empty()).collect();
                if !extra.is_empty() {
                    line.push_str(&format!(" ({})", extra.join(", ")));
                }
                line
            })
            .collect::<Vec<_>>()
            .join("\n");
        out.push_str(&format!("## To-do's\n\n{todos}\n\n"));
    }
    if !note.lines.is_empty() {
        let lines = note
            .lines
            .iter()
            .map(|l| {
                format!("**{}** ({}) : {}", note.speaker(&l.speaker).map(|s| s.name.as_str()).unwrap_or(&l.speaker), clock(l.start), l.text)
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        out.push_str(&format!("## Transcript\n\n{lines}\n"));
    }
    out
}

/// Notities die bij de woorden passen, beste eerst: een woord in titel of samenvatting telt meer dan in het transcript.
pub fn search<'a>(notes: &'a [Note], query: &str) -> Vec<&'a Note> {
    let words: Vec<String> = tokens(query).into_iter().filter(|w| w.chars().count() >= 2).collect();
    let mut sorted: Vec<&Note> = notes.iter().collect();
    sorted.sort_by_key(|b| std::cmp::Reverse(b.start));
    if words.is_empty() {
        return sorted;
    }
    let mut scored: Vec<(&Note, usize)> = sorted
        .into_iter()
        .filter_map(|note| {
            let head: BTreeSet<String> = tokens(&format!(
                "{} {} {} {}",
                note.title,
                note.summary.clone().unwrap_or_default(),
                note.key_points.join(" "),
                note.todos.iter().map(|t| t.text.as_str()).collect::<Vec<_>>().join(" ")
            ))
            .into_iter()
            .collect();
            let body: BTreeSet<String> =
                tokens(&note.lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>().join(" ")).into_iter().collect();
            let score: usize = words.iter().map(|w| if head.contains(w) { 3 } else { 0 } + if body.contains(w) { 1 } else { 0 }).sum();
            (score > 0).then_some((note, score))
        })
        .collect();
    scored.sort_by(|a, b| b.1.cmp(&a.1).then(b.0.start.cmp(&a.0.start)));
    scored.into_iter().map(|(n, _)| n).collect()
}

/// Eén regel per notitie voor het brein: id, datum, titel en samenvatting.
pub fn overview(note: &Note) -> String {
    let minutes = ((note.duration() / 60.0).round() as i64).max(1);
    let mut line = format!("- [{}] {} ({minutes} min) {}", note.id, note.start.with_timezone(&Local).format("%Y-%m-%d %H:%M"), note.title);
    if let Some(summary) = note.summary.as_ref().filter(|s| !s.is_empty()) {
        line.push_str(&format!(": {summary}"));
    }
    if !note.todos.is_empty() {
        line.push_str(&format!(" To-dos: {}", note.todos.iter().map(|t| t.text.as_str()).collect::<Vec<_>>().join("; ")));
    }
    line
}

/// De notities op schijf: één JSON-bestand per gesprek in de map `Notes`, alleen voor de gebruiker leesbaar.
#[derive(Debug, Clone)]
pub struct NoteStore {
    dir: PathBuf,
    /// Nieuwste eerst.
    pub notes: Vec<Note>,
}

impl NoteStore {
    pub fn open_default() -> Self {
        Self::open(paths::support_directory().join("Notes"))
    }

    pub fn open(dir: PathBuf) -> Self {
        let mut notes: Vec<Note> = std::fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| std::fs::read(e.path()).ok())
            .filter_map(|b| serde_json::from_slice::<Note>(&b).ok())
            .map(|mut n| {
                // Een opname die nooit afkwam (Nook stopte): niet eeuwig "bezig".
                if matches!(n.status, NoteStatus::Recording | NoteStatus::Processing) {
                    n.status = if n.lines.is_empty() { NoteStatus::Failed } else { NoteStatus::Ready };
                }
                n
            })
            .collect();
        notes.sort_by_key(|b| std::cmp::Reverse(b.start));
        Self { dir, notes }
    }

    pub fn save(&mut self, note: &Note) {
        match self.notes.iter_mut().find(|n| n.id == note.id) {
            Some(existing) => *existing = note.clone(),
            None => self.notes.insert(0, note.clone()),
        }
        if let Ok(bytes) = serde_json::to_vec_pretty(note) {
            let _ = paths::write_atomic(&self.dir.join(format!("{}.json", note.id)), &bytes);
        }
    }

    pub fn get(&self, id: &str) -> Option<&Note> {
        let id = id.trim().trim_matches(|c| c == '[' || c == ']' || c == ' ');
        self.notes.iter().find(|n| n.id == id || (id.len() >= 8 && n.id.starts_with(id)))
    }

    pub fn delete(&mut self, id: &str) {
        self.notes.retain(|n| n.id != id);
        let _ = std::fs::remove_file(self.dir.join(format!("{id}.json")));
    }

    pub fn ready(&self) -> Vec<Note> {
        self.notes.iter().filter(|n| n.status == NoteStatus::Ready).cloned().collect()
    }
}

/// Eén kant van een opname (microfoon of computergeluid), als 16 kHz mono. Geeft het stuk dat nog niet getranscribeerd
/// is af als het lang genoeg is en op een pauze eindigt (of te lang wordt om te wachten); stille stukken vallen weg.
#[derive(Debug, Default)]
pub struct LiveChannel {
    pending: Vec<f32>,
    pending_start: f64,
    total: usize,
    pub level: f32,
}

pub const SAMPLE_RATE: f64 = 16_000.0;

impl LiveChannel {
    pub fn append(&mut self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        self.level = rms(samples);
        self.pending.extend_from_slice(samples);
        self.total += samples.len();
    }

    pub fn take_chunk(&mut self, force: bool) -> Option<(f64, Vec<f32>)> {
        self.take_chunk_with(4.0, 25.0, force)
    }

    pub fn take_chunk_with(&mut self, min_seconds: f64, max_seconds: f64, force: bool) -> Option<(f64, Vec<f32>)> {
        let seconds = self.pending.len() as f64 / SAMPLE_RATE;
        if seconds < if force { 0.5 } else { min_seconds } {
            return None;
        }
        let tail = &self.pending[self.pending.len().saturating_sub((SAMPLE_RATE / 2.0) as usize)..];
        if !(force || rms(tail) < 0.012 || seconds >= max_seconds) {
            return None;
        }
        let start = self.pending_start;
        let samples = std::mem::take(&mut self.pending);
        self.pending_start = self.total as f64 / SAMPLE_RATE;
        (rms(&samples) >= 0.004).then_some((start, samples))
    }
}

pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn timed(text: &str, from: f64) -> Vec<TimedWord> {
        text.split(' ')
            .enumerate()
            .map(|(i, w)| TimedWord { text: w.into(), start: from + i as f64 * 0.3, end: from + i as f64 * 0.3 + 0.25 })
            .collect()
    }

    #[test]
    fn words_from_the_recognizer_are_placed_in_the_recording() {
        let placed = words(&[("hallo".into(), 0.2, 0.3), (" ".into(), 1.0, 0.0)], 30.0);
        assert_eq!(placed, vec![TimedWord { text: "hallo".into(), start: 30.2, end: 30.5 }]);
    }

    #[test]
    fn transcript_from_both_sides_without_the_echo() {
        let mine = [timed("zullen we vrijdag afspreken", 0.0), timed("de offerte komt morgen", 10.0)].concat();
        let theirs = [timed("prima vrijdag om tien uur", 3.0), timed("de offerte komt morgen", 10.1)].concat();
        let (speakers, lines) = build(&mine, &theirs, "Ik", "De anderen");
        assert_eq!(speakers.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), vec!["Ik", "De anderen"]);
        assert_eq!(
            lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            vec!["zullen we vrijdag afspreken", "prima vrijdag om tien uur", "de offerte komt morgen"]
        );
        assert_eq!(lines.last().unwrap().speaker, OTHERS_ID, "mijn microfoon die hun luidsprekers hoort ben ik niet");
    }

    #[test]
    fn summary_is_read_even_with_text_around() {
        let reply = "Hier zijn de notities:\n```json\n{\"title\": \"Offerte Lisa\", \"summary\": \"We spreken vrijdag af.\", \"key_points\": [\"Vrijdag 10 uur\"], \"todos\": [{\"text\": \"Offerte sturen\", \"owner\": \"Ik\", \"due\": \"morgen\"}, {\"text\": \"Agenda checken\", \"owner\": null, \"due\": \"null\"}]}\n```";
        let summary = parse_summary(reply).unwrap();
        assert_eq!(summary.title.as_deref(), Some("Offerte Lisa"));
        assert_eq!(summary.todos[0].due.as_deref(), Some("morgen"));
        assert_eq!(summary.todos[1].owner, None);
        assert_eq!(summary.todos[1].due, None);
        assert!(parse_summary("geen json").is_none());
    }

    #[test]
    fn search_and_overview() {
        let base = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        let mut older = Note::new("Sprint", base);
        older.lines = vec![NoteLine::new("me", 0.0, 2.0, "de offerte van Lisa")];
        older.end = Some(base + chrono::Duration::seconds(600));
        let later = DateTime::from_timestamp(1_800_000_000, 0).unwrap();
        let mut newer = Note::new("Offerte Lisa", later);
        newer.summary = Some("Afspraak vrijdag.".into());
        newer.todos = vec![NoteTodo::new("Offerte sturen", None, None)];
        newer.end = Some(later + chrono::Duration::seconds(1800));
        let notes = vec![older, newer.clone()];
        let found = search(&notes, "offerte");
        assert_eq!(
            found.iter().map(|n| n.title.as_str()).collect::<Vec<_>>(),
            vec!["Offerte Lisa", "Sprint"],
            "een woord in de titel telt meer"
        );
        assert!(search(&notes, "budget").is_empty());
        let line = overview(&newer);
        assert!(line.contains("(30 min) Offerte Lisa: Afspraak vrijdag. To-dos: Offerte sturen"), "{line}");
        assert!(line.contains(&newer.id));
    }

    #[test]
    fn markdown_and_clock() {
        let mut note = Note::new("Call", Utc::now());
        note.speakers = vec![NoteSpeaker { id: "me".into(), name: "Ik".into(), color: 0, is_me: true }];
        note.lines = vec![NoteLine::new("me", 75.0, 77.0, "hallo")];
        note.todos = vec![NoteTodo::new("Bellen", Some("Ik".into()), None)];
        let md = markdown(&note);
        assert!(md.contains("- [ ] Bellen (Ik)"));
        assert!(md.contains("**Ik** (1:15) : hallo"));
        assert_eq!(clock(3725.0), "1:02:05");
    }

    #[test]
    fn live_channel_cuts_on_a_pause() {
        let mut channel = LiveChannel::default();
        let speech: Vec<f32> = (0..16_000 * 5).map(|i| ((i as f32) * 0.05).sin() * 0.3).collect();
        channel.append(&speech);
        assert!(channel.take_chunk(false).is_none(), "nog midden in een zin");
        channel.append(&vec![0.0; 8000]);
        let (start, samples) = channel.take_chunk(false).unwrap();
        assert_eq!(start, 0.0);
        assert_eq!(samples.len(), 16_000 * 5 + 8000);
        channel.append(&vec![0.0; 16_000 * 5]);
        assert!(channel.take_chunk(false).is_none(), "stilte valt weg");
    }

    #[test]
    fn store_round_trip() {
        let dir = std::env::temp_dir().join(format!("nook-notes-{}", uuid::Uuid::new_v4()));
        let mut store = NoteStore::open(dir.clone());
        let mut note = Note::new("Call", Utc::now());
        note.status = NoteStatus::Ready;
        store.save(&note);
        let again = NoteStore::open(dir.clone());
        assert_eq!(again.notes.len(), 1);
        assert!(again.get(&note.id[..8]).is_some());
        let _ = std::fs::remove_dir_all(dir);
    }
}
